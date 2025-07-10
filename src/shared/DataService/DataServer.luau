local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProfileStore
if RunService:IsServer() then
	local ServerScriptService = game:GetService("ServerScriptService")
	ProfileStore = require(ServerScriptService.ProfileStore)
end

local Relay = require(ReplicatedStorage.Shared.Relay)
local Util = require(script.Parent.DataUtil)
local Sift = require(script.Parent.Packages.Sift)

--[=[
DataService server handles all backend datastore setup and enables replication to the client

@class DataService 
@server
]=]
local DataService = {
	_profiles = {},
	options = {},

	__DEBUG = RunService:IsStudio(),
	started = false,
}

--[=[
@type DataServiceOptions {  template: { [string]: any },  Whitelist: { any }?,  enforceReferentialIntegrity: ((Player) -> ())?,  useMock: boolean?,  yieldFunctionsUntilLoaded: boolean? }
@within DataService
The options to provide in the :init() function
]=]
export type DataServiceOptions = {
	template: { [string]: any },
	Whitelist: { any }?,
	Blacklist: { any }?,
	enforceReferentialIntegrity: ((Player) -> ())?,
	useMock: boolean?,
	yieldFunctionsUntilLoaded: boolean?,
}

local function Debug(Message: string, Method: any)
	if not DataService.__DEBUG then
		return
	end
	Method = Method or print
	Method(Message)
end

--[=[
Initializes the service and sets up key prerequisites to use in later functions. Must be called from a server-script

@within DataService
@param options DataServiceOptions -- The table of options that determines the behaviour of the service	
@return ()
]=]
function DataService:init(options: DataServiceOptions): ()
	assert(RunService:IsServer(), Util.STANDARD_ERR .. "DataService.Server can only be ran on the server")
	assert(options and typeof(options) == "table", Util.STANDARD_ERR .. "No options provided")

	self.Whitelist = options.Whitelist
	self.Blacklist = options.Blacklist

	self.Relay = Relay.server.new("DataService@1.0", self, options.Whitelist, options.Blacklist) :: typeof(Relay.server)
	self.Relay.Module = self
	if options.enforceReferentialIntegrity then
		self.Relay:enforceReferentialIntegrity(options.enforceReferentialIntegrity)
	end

	assert(options.template, Util.STANDARD_ERR .. "Template is nil")
	self._profileStore = ProfileStore.New("PlayerStore", options.template)
	self.yieldGetReq = options.yieldFunctionsUntilLoaded or true

	if options.useMock then
		self._profileStore = self._profileStore.Mock
	end

	for _, player in Players:GetChildren() do
		self:_playerAdded(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:_playerAdded(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_playerRemoving(player)
	end)

	self.started = true
end

--[=[
Retrieves all data or a player's profile data if a player is provided.
If player data hasn't loaded yet, function will yield until their data is loaded.

@param Player Player? -- The player who's data you want to retrieve

@within DataService
@return {}
]=]
function DataService:getData(Player: Player?): { any }
	local profile = self._profiles[tostring(Player.UserId)]
	local data = (profile and (Player and self._profiles[tostring(Player.UserId)].Data)) or self._profiles
	if (Sift.Dictionary.count(data) < 1) and self.yieldGetReq then
		task.wait()
		return self:getData(Player)
	end

	return data
end

--[=[
Fetches the value at the given string path from a player's data.

@param Player Player -- The player whose data is being accessed
@param stringPath string -- The string path pointing to the desired data within the player's profile

@within DataService
@return any -- The value retrieved from the specified path in the player's data
]=]
function DataService:fetch(Player: Player, stringPath: string)
	local data = self:getData(Player)
	local path, lastKey = Relay.util:getIndexValueFromString(stringPath, data)
	return path[lastKey]
end

--[=[
Waits asynchronously until a player's data has been loaded.

@within DataService
@param Player Player | { Player } -- The player whose data you are waiting for
@return () -- Returns when the data is available
]=]
function DataService:awaitPlayerDataAsync(Player: Player | { Player }): ()
	assert(Player and typeof(Player) == "Instance", Util.STANDARD_ERR .. "Player parameter is invalid")

	local pData = self:getData(Player)
	if pData then
		return pData
	end

	repeat
		task.wait()
	until self:getData(Player) ~= nil
end

function DataService:_updateListForPlayer(Player: Player, list: {})
	if not list then
		return {}
	end
	local copy = table.clone(list)
	for i, stringPath in ipairs(copy) do
		if typeof(stringPath) == "string" then
			copy[i] = Util:getDataStringPath(Player) .. "." .. stringPath
		end
	end
	return copy
end

--[=[
Sets the index to the given value for all the players provided

Example:
```lua
local Cash = DataService:fetch(Player, "Cash") -- 250
DataService:setData(Player, "Cash", Cash * 2)
print(DataService:fetch(Player, "Cash")) -- 500
```

@param Player Player | { Player } -- The player(s) who's data you want modify
@param stringPath string -- The string path of the index you want to modify e.g. ``Settings.MaxVolume``
@param value any -- The value you want to modify the index(s) with

@within DataService
@return ()
]=]
function DataService:setData(Player: Player, stringPath: string, value: any): ()
	if typeof(Player) == "Instance" then
		Player = { Player }
	end
	for _, Plr in Player do
		self.Relay.Whitelist = self:_updateListForPlayer(Plr, self.Whitelist)
		self.Relay.Blacklist = self:_updateListForPlayer(Plr, self.Blacklist)
		self:awaitPlayerDataAsync(Plr)
		local path = Util:getDataStringPath(Plr) .. "." .. stringPath

		local result = self.Relay:setValueFromStringIndex(Plr, path, value)
		if result then
			local clientPath = Util.Enums.LOCAL_PATH .. "." .. stringPath
			self.Relay:set(Plr, clientPath, value)
		end
	end
end

--[=[
Sets the index to the given value for every player

@param stringPath string -- The string path of the index you want to modify e.g. ``Settings.MaxVolume``
@param value any -- The value you want to modify the index(s) with

@within DataService
@return ()
]=]
function DataService:setAllData(stringPath: string, value: any): ()
	self:setData(Players:GetChildren(), stringPath, value)
end

--[=[
Sets the index to the given value for every player

@param Player Player | { Player } -- The player(s) who you want to exclude from the modification
@param stringPath string -- The string path of the index you want to modify e.g. ``Settings.MaxVolume``
@param value any -- The value you want to modify the index(s) with

@within DataService
@return ()
]=]
function DataService:setAllDataExcept(Player: Player | { Player }, stringPath: string, value: any): ()
	if typeof(Player) == "Instance" then
		Player = { Player }
	end
	local plrs = Players:GetChildren()
	for _, plr in plrs do
		if not table.find(Player, plr) then
			self:setData(plr, stringPath, value)
		end
	end
end

function DataService:removeDataAsync(UserID: number)
	assert(RunService:IsRunning(), Util.RUN_ERR)

	ProfileStore:RemoveAsync(UserID)
	Debug("Removed data")
end

--[=[
Returns true if the service has been initialized, otherwise false

@within DataService
@return boolean
]=]
function DataService:checkInit()
	return self.started
end

--[=[
Asserts that the DataService has been initialized.

@within DataService
@error boot_error -- Throws if the service is not initialized
@return ()
]=]
function DataService:_enforceInit()
	assert(self:checkInit(), Util.BOOT_ERR)
end

--[=[
Attempts to load player data and replicates the retrieved data to the client. 

@within DataService
@error You should not use this function as players are automatically detected and this function is called once the service is initialized
@return ()
]=]
function DataService:_playerAdded(Player: Player)
	local profile = self._profileStore:StartSessionAsync(`{Player.UserId}`, {
		Cancel = function()
			return Player.Parent ~= Players
		end,
	})

	if profile then
		profile:AddUserId(Player.UserId)
		profile:Reconcile()

		profile.OnSessionEnd:Connect(function()
			self:cleanup()
			Player:Kick("Profile session end - please rejoin")
		end)

		if not (Player.Parent == Players) then
			profile:EndSession()
		else
			Debug(`Successfully loaded {Player.Name}'s data`)
			self._profiles[tostring(Player.UserId)] = profile
			self.Relay:fire(Player, "SyncData", profile.Data)
		end
	else
		Player:Kick("Failed to load data, this is likely a ROBLOX issue - please rejoin")
		self:cleanup(tostring(Player.UserId))
	end
end

--[=[
Attempts to save player data

@within DataService
@error You should not use this function as players are automatically detected and this function is called once they leave
@return ()
]=]
function DataService:_playerRemoving(Player: Player)
	local profile = self._profiles[tostring(Player.UserId)]
	if profile then
		Debug("Player data saved")
		profile:EndSession()
	end
end

--[=[
Cleans up a player's profile store, should their session end

@param Key string -- The key for the data you want to cleanup

@within DataService
@ignore
@return ()
]=]
function DataService:cleanup(Key: string)
	if self._profiles[Key] then
		self._profiles[Key] = nil
	end
	Debug("Successfully cleaned up player data")
end

return DataService
