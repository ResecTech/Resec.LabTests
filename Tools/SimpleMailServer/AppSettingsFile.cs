using System.Text.Json;
using System.Text.Json.Nodes;

namespace SimpleMailServer;

internal static class AppSettingsFile
{
    private static string SettingsFilePath =>
        Path.Combine(AppContext.BaseDirectory, "appsettings.json");

    public static void SaveResponseDelaySeconds(double responseDelaySeconds)
    {
        string json = File.ReadAllText(SettingsFilePath);
        JsonObject root = JsonNode.Parse(json)?.AsObject()
            ?? throw new InvalidOperationException("appsettings.json root must be an object.");

        JsonObject smtpSettings = root["SmtpSettings"]?.AsObject() ?? new JsonObject();
        smtpSettings["ResponseDelaySeconds"] = responseDelaySeconds;
        root["SmtpSettings"] = smtpSettings;

        var options = new JsonSerializerOptions { WriteIndented = true };
        File.WriteAllText(SettingsFilePath, root.ToJsonString(options));
    }
}
