# DataService
[![Docs](https://img.shields.io/badge/docs-website-green.svg)](https://qxshio.github.io/DataService)
### Last updated 10/07/2025
DataService server handles all backend datastore setup + saving and enables replication to the client

## Getting Started
To build the place from scratch, use:

```bash
rojo build -o "DataService.rbxlx"
```

Next, open `DataService.rbxlx` in Roblox Studio and start the Rojo server:

```bash
rojo serve
```

## Initialization:
### Client Example:
```luau
local DataService = require(path.to.require)

DataService.client:init()
```
### Server Example:
```luau
local DataService = require(path.to.require)

DataService.server:init({
	template = {
		Cash = 0,
		Settings = {
			SFXVolume = 0.5,
			UIVolume = 0.5,
			MusicVolume = 0.5,
		},
	},
	Whitelist = {
		"Settings.*",
	},
	enforceReferentialIntegrity = function(FlaggedUser: Player)
		FlaggedUser:Kick(
			"[DS ANTI-TAMPER] You were flagged for illegal modification of server data. Your progress has been saved."
		)
	end,
})
```
