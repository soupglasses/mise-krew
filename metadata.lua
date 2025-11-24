-- metadata.lua
-- Backend plugin metadata and configuration
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    -- Required: Plugin name (will be the backend name users reference)
    name = "krew",

    -- Required: Plugin version (not the tool versions)
    version = "1.0.1",

    -- Required: Brief description of the backend and tools it manages
    description = "A mise backend plugin for krew tools",

    -- Required: Plugin author/maintainer
    author = "soupglasses",

    -- Optional: Plugin homepage/repository URL
    homepage = "https://github.com/soupglasses/mise-krew",

    -- Optional: Plugin license
    license = "MIT",

    -- Optional: Important notes for users
    notes = {
        -- "Requires <BACKEND> to be installed on your system",
        -- "This plugin manages tools from the <BACKEND> ecosystem"
    },
}
