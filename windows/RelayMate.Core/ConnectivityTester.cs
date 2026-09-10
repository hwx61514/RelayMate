using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RelayMate.Core;

public sealed class ConnectivityTester
{
    private static readonly HashSet<HttpStatusCode> WrongEndpointStatuses =
    [
        HttpStatusCode.BadRequest,
        HttpStatusCode.NotFound,
        HttpStatusCode.MethodNotAllowed,
        HttpStatusCode.UnsupportedMediaType,
        HttpStatusCode.UnprocessableEntity,
        HttpStatusCode.NotImplemented
    ];

    private readonly HttpClient _client;

    public ConnectivityTester(HttpClient? client = null)
    {
        _client = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
    }

    public async Task ValidateAsync(
        RelayConfiguration input,
        ClientKind client,
        CancellationToken cancellationToken = default)
    {
        var configuration = input.Normalize();
        var baseUri = ValidateBaseUri(configuration.BaseUrl);
        if (configuration.Model.Length == 0)
        {
            throw RelayMateException.MissingModel();
        }
        if (configuration.ApiKey.Length == 0)
        {
            throw RelayMateException.MissingApiKey();
        }

        var result = await ProbeAsync(configuration, baseUri, client, false, cancellationToken);
        if (result.Success)
        {
            return;
        }
        if (client != ClientKind.Codex || !result.SuggestsWrongEndpoint)
        {
            throw result.Error!;
        }

        var chatResult = await ProbeAsync(configuration, baseUri, client, true, cancellationToken);
        if (!chatResult.Success)
        {
            throw result.Error!;
        }
        throw RelayMateException.Incompatible(
            "该中转站只提供 Chat Completions 接口，没有 Responses 接口。Codex 已移除 wire_api = \"chat\" 支持。");
    }

    public async Task<ModelCatalog> FetchModelsAsync(
        string baseUrl,
        string apiKey,
        CancellationToken cancellationToken = default)
    {
        var baseUri = ValidateBaseUri(baseUrl);
        using var request = new HttpRequestMessage(HttpMethod.Get, ModelsUri(baseUri));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey.Trim());
        using var response = await SendWithRetryAsync(request, cancellationToken);
        var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw RelayMateException.Incompatible($"模型列表请求失败，{FailureDetail(data, response.StatusCode)}");
        }
        var catalog = ParseModels(data);
        if (catalog.Models.Count == 0)
        {
            throw RelayMateException.Incompatible("中转站返回了空模型列表。");
        }
        return catalog;
    }

    public static Uri ValidateBaseUri(string value)
    {
        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri)
            || uri.Scheme is not ("http" or "https")
            || string.IsNullOrWhiteSpace(uri.Host))
        {
            throw RelayMateException.InvalidUrl();
        }
        if (uri.Scheme == "http" && !IsLoopback(uri.Host))
        {
            throw RelayMateException.InsecureUrl();
        }
        return uri;
    }

    public static ModelCatalog ParseModels(byte[] data)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(Encoding.UTF8.GetString(data).TrimStart('\uFEFF'));
        }
        catch (JsonException)
        {
            throw RelayMateException.Incompatible("模型列表不是有效的 JSON。");
        }

        var items = root switch
        {
            JsonObject value when value["data"] is JsonArray array => array,
            JsonObject value when value["models"] is JsonArray array => array,
            JsonArray array => array,
            _ => new JsonArray()
        };
        var capabilities = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            string? identifier = null;
            var supportsOneMillion = false;
            if (item is JsonValue value && value.TryGetValue<string>(out var text))
            {
                identifier = text;
            }
            else if (item is JsonObject model)
            {
                identifier = JsonFiles.String(model, "id") ?? JsonFiles.String(model, "name");
                supportsOneMillion = JsonFiles.Bool(model, "supports1m") || JsonFiles.Bool(model, "supports_1m");
            }
            identifier = identifier?.Trim();
            if (string.IsNullOrEmpty(identifier))
            {
                continue;
            }
            capabilities[identifier] = capabilities.GetValueOrDefault(identifier) || supportsOneMillion;
        }

        var models = capabilities.Keys.Order(StringComparer.OrdinalIgnoreCase).ToList();
        var oneMillion = capabilities.Where(item => item.Value)
            .Select(item => item.Key)
            .ToHashSet(StringComparer.Ordinal);
        return new ModelCatalog(models, oneMillion);
    }

    private async Task<ProbeResult> ProbeAsync(
        RelayConfiguration configuration,
        Uri baseUri,
        ClientKind client,
        bool chatCompletions,
        CancellationToken cancellationToken)
    {
        var endpoint = EndpointUri(baseUri, client, chatCompletions);
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", configuration.ApiKey);
        if (client == ClientKind.Claude)
        {
            request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        }
        object body = client switch
        {
            ClientKind.Claude => new
            {
                model = configuration.Model,
                max_tokens = 1,
                messages = new[] { new { role = "user", content = "Reply with OK" } }
            },
            _ when chatCompletions => new
            {
                model = configuration.Model,
                max_tokens = 16,
                messages = new[] { new { role = "user", content = "Reply with OK" } }
            },
            _ => new { model = configuration.Model, input = "Reply with OK", max_output_tokens = 16 }
        };
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

        try
        {
            using var response = await SendWithRetryAsync(request, cancellationToken);
            var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (response.IsSuccessStatusCode)
            {
                return ProbeResult.Ok();
            }
            var detail = FailureDetail(data, response.StatusCode);
            var error = response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                ? RelayMateException.Incompatible($"API Key 未通过验证，{detail}")
                : RelayMateException.Incompatible($"{(client == ClientKind.Claude ? "Anthropic Messages" : chatCompletions ? "Chat Completions" : "Responses")} 请求失败，{detail}");
            return ProbeResult.Failed(error, WrongEndpointStatuses.Contains(response.StatusCode));
        }
        catch (RelayMateException exception)
        {
            return ProbeResult.Failed(exception, false);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            return ProbeResult.Failed(RelayMateException.Network(exception.Message), false);
        }
    }

    private async Task<HttpResponseMessage> SendWithRetryAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        byte[]? content = request.Content is null
            ? null
            : await request.Content.ReadAsByteArrayAsync(cancellationToken);
        var headers = request.Headers.ToList();
        var contentHeaders = request.Content?.Headers.ToList() ?? [];

        for (var attempt = 1; attempt <= 2; attempt++)
        {
            using var clone = new HttpRequestMessage(request.Method, request.RequestUri);
            foreach (var header in headers)
            {
                clone.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
            if (content is not null)
            {
                clone.Content = new ByteArrayContent(content);
                foreach (var header in contentHeaders)
                {
                    clone.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
                }
            }

            try
            {
                var response = await _client.SendAsync(clone, cancellationToken);
                if (attempt < 2 && IsTransient(response.StatusCode))
                {
                    response.Dispose();
                    await Task.Delay(800, cancellationToken);
                    continue;
                }
                return response;
            }
            catch (HttpRequestException) when (attempt < 2)
            {
                await Task.Delay(800, cancellationToken);
            }
            catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested && attempt < 2)
            {
                await Task.Delay(800, cancellationToken);
            }
        }
        throw RelayMateException.Network("请求未能完成。");
    }

    private static bool IsTransient(HttpStatusCode status) =>
        status is HttpStatusCode.RequestTimeout or (HttpStatusCode)425
        || ((int)status >= 500 && status is not HttpStatusCode.NotImplemented and not HttpStatusCode.HttpVersionNotSupported);

    private static bool IsLoopback(string host) =>
        host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
        || IPAddress.TryParse(host, out var address) && IPAddress.IsLoopback(address)
        || host == "[::1]";

    private static Uri ModelsUri(Uri baseUri)
    {
        var path = baseUri.AbsolutePath.TrimEnd('/');
        path = path.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
            ? path
            : path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
                ? $"{path}/models"
                : $"{path}/v1/models";
        return WithPath(baseUri, path);
    }

    private static Uri EndpointUri(Uri baseUri, ClientKind client, bool chatCompletions)
    {
        var path = baseUri.AbsolutePath.TrimEnd('/');
        if (client == ClientKind.Claude)
        {
            if (path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
            {
                path = path[..^3];
            }
            path += "/v1/messages";
        }
        else
        {
            var endpoint = chatCompletions ? "chat/completions" : "responses";
            path += path.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
                ? $"/{endpoint}"
                : $"/v1/{endpoint}";
        }
        return WithPath(baseUri, path);
    }

    private static Uri WithPath(Uri value, string path)
    {
        var builder = new UriBuilder(value) { Path = path };
        return builder.Uri;
    }

    private static string FailureDetail(byte[] data, HttpStatusCode status)
    {
        string? message = null;
        try
        {
            var root = JsonNode.Parse(Encoding.UTF8.GetString(data).TrimStart('\uFEFF')) as JsonObject;
            message = root?["error"] is JsonObject error
                ? JsonFiles.String(error, "message")
                : JsonFiles.String(root, "message");
        }
        catch (JsonException)
        {
            message = Encoding.UTF8.GetString(data.AsSpan(0, Math.Min(data.Length, 240))).Trim();
        }
        return string.IsNullOrWhiteSpace(message)
            ? $"HTTP {(int)status}"
            : $"{message[..Math.Min(message.Length, 240)]}（HTTP {(int)status}）";
    }

    private sealed record ProbeResult(bool Success, RelayMateException? Error, bool SuggestsWrongEndpoint)
    {
        public static ProbeResult Ok() => new(true, null, false);
        public static ProbeResult Failed(RelayMateException error, bool suggestsWrongEndpoint) =>
            new(false, error, suggestsWrongEndpoint);
    }
}
