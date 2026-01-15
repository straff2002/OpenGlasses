import Foundation

/// App configuration and API keys
struct Config {
    /// Anthropic API key for Claude
    static var anthropicAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "anthropicAPIKey"), !key.isEmpty {
            return key
        }
        // Default key - replace with your own or set via Settings
        return "YOUR_ANTHROPIC_API_KEY_HERE"
    }
    
    static func setAnthropicAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "anthropicAPIKey")
    }
    
    /// Wake word phrase
    static let wakePhrase = "hey claude"
    
    /// Alternative wake phrases for better recognition
    static let alternativeWakePhrases = ["hey cloud", "hey claud", "hey clod"]
    
    /// Claude model to use
    static let claudeModel = "claude-sonnet-4-20250514"
    
    /// Max tokens for Claude response
    static let maxTokens = 1024
}
