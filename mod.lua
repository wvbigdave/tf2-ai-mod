function data()
    return {
        info = {
            minorVersion = 3,
            severityAdd = "NONE",
            severityRemove = "NONE",
            name = _("AI_RALPHY_TEST_ACTIVE"),
            description = _("Host mod for external Python AI agents. Provides IPC via /tmp/tf2_ai_commands.json. Gemini LLM integration."),
            tags = { "Script Mod" },
            authors = {
                {
                    name = "TF2 AI Optimizer",
                    role = "CREATOR",
                }
            },
            version = "1.3.4",
        },
    }
end
