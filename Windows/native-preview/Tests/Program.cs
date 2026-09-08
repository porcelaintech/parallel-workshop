using Braintrust.NativePreview;

var config = args.Length == 1 ? args[0] : throw new ArgumentException("Pass Config/platforms.json.");
var platforms = PlatformPolicy.Load(config);
var chat = platforms.Single(p => p.Id == "chatgpt");
var checks = 0;
void Check(bool value, string message) { checks++; if (!value) throw new Exception(message); }
Check(PlatformPolicy.IsAllowed(chat, "https://chatgpt.com/"), "Expected platform homepage.");
Check(PlatformPolicy.IsAllowed(chat, "https://AUTH.OPENAI.COM/login"), "Expected exact trusted auth host.");
foreach (var url in new[] {
    "https://chatgpt.com.attacker.example/", "https://evilchatgpt.com/", "https://sub.chatgpt.com/",
    "https://chatgpt.com@attacker.example/", "https://attacker@chatgpt.com/", "http://chatgpt.com/",
    "file:///C:/private.txt", "javascript:alert(1)", "ms-appinstaller:?source=https://attacker.example/",
    "https://chatgpt.com:444/", "https://127.0.0.1/", "//chatgpt.com/", "about:blank"
}) Check(!PlatformPolicy.IsAllowed(chat, url), $"Unsafe navigation allowed: {url}");
Check(platforms.Select(p => p.ProfileName).Distinct().Count() == 3, "Sessions must have separate stable profiles.");
Check(!PlatformPolicy.IsAllowed(platforms.Single(p => p.Id == "deepseek"), chat.Origin), "No cross-platform navigation privilege.");
Check(PlatformPolicy.DisplayOrigin("https://auth.openai.com/callback?code=SECRET#token") == "https://auth.openai.com",
    "Diagnostic origin must redact paths, query strings and fragments.");
Check(!PlatformPolicy.TryHttps("https://user:SECRET@chatgpt.com", out _), "Credentials cannot be externalized.");
Console.WriteLine($"{checks} navigation/session policy checks passed; no WebView2, login or package runtime was tested.");
