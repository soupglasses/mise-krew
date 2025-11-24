-- metadata.lua
-- Backend plugin metadata and configuration
-- Documentation: https://mise.jdx.dev/backend-plugin-development.html

PLUGIN = { -- luacheck: ignore
    -- Required: Plugin name (will be the backend name users reference)
    name = "<BACKEND>",

    -- Required: Plugin version (not the tool versions)
    version = "1.0.0",

    -- Required: Brief description of the backend and tools it manages
    description = "A mise backend plugin for <BACKEND> tools",

    -- Required: Plugin author/maintainer
    author = "<GITHUB_USER>",

    -- Optional: Plugin homepage/repository URL
    homepage = "https://github.com/<GITHUB_USER>/<BACKEND>",

    -- Optional: Plugin license
    license = "MIT",

    -- Optional: Important notes for users
    notes = {
        -- "Requires <BACKEND> to be installed on your system",
        -- "This plugin manages tools from the <BACKEND> ecosystem"
    },
}
