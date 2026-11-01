using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NativeScreen.Core;

public static class ProjectJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    public static JsonSerializerOptions Compact { get; } = Create(writeIndented: false);

    public static T Deserialize<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options) ?? throw new JsonException($"Could not read {typeof(T).Name}.");

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static T Clone<T>(T value) => Deserialize<T>(JsonSerializer.Serialize(value, Compact));

    private static JsonSerializerOptions Create(bool writeIndented = true)
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            WriteIndented = writeIndented,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        };
        options.Converters.Add(new JsonStringEnumConverter());
        options.Converters.Add(new IntKeyDictionaryConverterFactory());
        return options;
    }
}

public sealed class IntKeyDictionaryConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert)
    {
        if (!typeToConvert.IsGenericType || typeToConvert.GetGenericTypeDefinition() != typeof(Dictionary<,>))
        {
            return false;
        }

        return typeToConvert.GetGenericArguments()[0] == typeof(int);
    }

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options)
    {
        var valueType = typeToConvert.GetGenericArguments()[1];
        var converterType = typeof(IntKeyDictionaryConverter<>).MakeGenericType(valueType);
        return (JsonConverter)(Activator.CreateInstance(converterType) ?? throw new InvalidOperationException());
    }
}

public sealed class IntKeyDictionaryConverter<TValue> : JsonConverter<Dictionary<int, TValue>>
{
    public override Dictionary<int, TValue> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
        {
            return [];
        }

        if (reader.TokenType != JsonTokenType.StartObject)
        {
            throw new JsonException("Expected an object keyed by integer strings.");
        }

        var result = new Dictionary<int, TValue>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndObject)
            {
                return result;
            }

            if (reader.TokenType != JsonTokenType.PropertyName)
            {
                throw new JsonException();
            }

            var keyText = reader.GetString() ?? throw new JsonException();
            if (!int.TryParse(keyText, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var key))
            {
                throw new JsonException($"Expected an integer key, got '{keyText}'.");
            }

            reader.Read();
            var value = JsonSerializer.Deserialize<TValue>(ref reader, options);
            if (value is null)
            {
                throw new JsonException();
            }

            result[key] = value;
        }

        throw new JsonException();
    }

    public override void Write(Utf8JsonWriter writer, Dictionary<int, TValue> value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        foreach (var pair in value.OrderBy(pair => pair.Key))
        {
            writer.WritePropertyName(pair.Key.ToString(System.Globalization.CultureInfo.InvariantCulture));
            JsonSerializer.Serialize(writer, pair.Value, options);
        }

        writer.WriteEndObject();
    }
}
