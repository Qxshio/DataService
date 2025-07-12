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
local Signal = require(script.Parent.Packages.Signal)

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
@type templateOption { value: any, readonly: boolean?, createLeaderstat: { Name: string, Format: (Value: any) -> string }?, whitelisted: boolean?, savingEnabled: boolean? }
@within DataService
The options to provide in the template
]=]
export type templateOptions = {
	value: any,
	readonly: boolean?,
	createLeaderstat: { Name: string, Format: (Value: any) -> string }?,
	whitelisted: boolean?,
	savingEnabled: boolean?,
}

--[=[
@type DataServiceOptions {  template: { [string]: any },  Whitelist: { any }?,  enforceReferentialIntegrity: ((Player) -> ())?,  useMock: boolean?,  yieldFunctionsUntilLoaded: boolean? }
@within DataService
The options to provide in the :init() function
]=]
export type DataServiceOptions = {
	template: { [string]: templateOptions },
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
Recursively processes a data template to extract and store whitelisted paths and leaderstat settings.
Modifies the template in-place by replacing template option tables with their `.value` fields.

@param template {} -- The nested table structure defining data schema and metadata (e.g., whitelisted, leaderstats)
@param currentPath string? -- (Optional) The current string path used during recursion

@ignore
@within DataService
@return nil
]=]
function DataService:_constructData(template: {}, currentPath: string?)
	for i, v in template do
		local stringPath = (currentPath and currentPath .. "." .. i) or i
		if typeof(v) == "table" and not v.value then
			self:_constructData(v, stringPath)
			continue
		end
		assert(
			typeof(v) == "table",
			Util.STANDARD_ERR .. "Provided template option does not follow the format of type `templateOption` (docs)"
		)

		if v.whitelisted == true then
			table.insert(self.Whitelist, stringPath)
		end
		if v.createLeaderstat then
			local Settings = v.createLeaderstat
			Settings.stringPath = stringPath
			self._leaderstats = self._leaderstats or {}
			self._leaderstats[i] = Settings
		end
		if v.savingEnabled == false then
			self.mockTemplate[i] = v.value
			template[i] = nil
			continue
		end

		template[i] = v.value
	end
end

--[=[
Creates or updates the "leaderstats" folder for a player based on configured leaderstat settings.
Fetches values from the player's data and applies optional formatting before assigning them to leaderstats.

@param Player Player -- The player for whom leaderstats should be created or updated

@ignore
@within DataService
@return nil
]=]
function DataService:_buildLeaderstats(Player: Player)
	if not self._leaderstats then
		return
	end
	local leaderstats = Player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = Player
	end

	for _, Settings: {} in self._leaderstats do
		local value = self:fetch(Player, Settings.stringPath)
		local formattedValue: string = Settings.Format and Settings.Format(value) or value

		local stat = leaderstats:FindFirstChild(Settings.Name)
		if not stat then
			stat = Instance.new("StringValue")
			stat.Name = Settings.Name
			stat.Parent = leaderstats
		end
		stat.Value = tostring(formattedValue)
	end
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

	self.Whitelist = options.Whitelist or {}
	self.mockTemplate = options.mockTemplate or {}
	self._changedSignals = {}
	self:_constructData(options.template)

	self.Relay = Relay.server.new("DataService@1.0", self, options.Whitelist, options.Blacklist)
	self.Relay.Module = self
	if options.enforceReferentialIntegrity then
		self.Relay:enforceReferentialIntegrity(options.enforceReferentialIntegrity)
	end

	assert(options.template, Util.STANDARD_ERR .. "Template is nil")

	self._profileStore = ProfileStore.New("DataServerStore", options.template)
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
	if Player then
		local data = self._profiles[`{Player.UserId}`] or {}
		if (Sift.Dictionary.count(data) < 1) and self.yieldGetReq then
			task.wait()
			return self:getData(Player)
		end
		return data.mock
	else
		return self._profiles
	end
end

--[=[
Retrieves and/or creates a Signal that is fired whenever the provided key's value changes
@param key string -- The value to listen to, should it be changed

@within DataService
@return Signal
]=]
function DataService:getServerChangedSignal<T>(key: string)
	if not self._changedSignals[key] then
		self._changedSignals[key] = Signal.new()
	end

	return self._changedSignals[key] :: Signal.Signal<T>
end

--[=[
Fetches the value at the given string path from a player's data.

@param Player Player -- The player whose data is being accessed
@param stringPath string -- The string path pointing to the desired data within the player's profile

@within DataService
@return any -- The value retrieved from the specified path in the player's data
]=]
function DataService:fetch(Player: Player, stringPath: string)
	self:awaitPlayerDataAsync(Player)
	local mockPath = Util:getDataStringPath(Player, true) .. "." .. stringPath
	local path, lastKey = Relay.util:getIndexValueFromString(mockPath, self)

	return path and path[lastKey]
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
	if not list or Sift.Dictionary.count(list) < 1 then
		return {}
	end
	local copy = table.clone(list)
	for i, stringPath in ipairs(copy) do
		if typeof(stringPath) == "string" then
			copy[i] = Util:getDataStringPath(Player) .. "." .. stringPath
			copy[i] = Util:getDataStringPath(Player, true) .. "." .. stringPath
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
OR
```lua
DataService:setData(Player, "Cash", function(OldCash: any)
	return OldCash * 2
end) -- 500
```

@param Player Player | { Player } -- The player(s) who's data you want modify
@param stringPath string -- The string path of the index you want to modify e.g. ``Settings.MaxVolume``
@param value any -- The value or function you want to modify the index with
@param useMock boolean? -- Whether or not the function should set the value in the mock data only
@param fromClient boolean? -- Whether or not security should be enabled, this should only be used if you're using client data to determine value allocation

@within DataService
@return ()
]=]
function DataService:setData(
	Player: Player,
	stringPath: string,
	value: any,
	useMock: boolean?,
	fromClient: boolean?
): ()
	if typeof(Player) == "Instance" then
		Player = { Player }
	end
	for _, Plr in Player do
		self.Relay.Whitelist = self:_updateListForPlayer(Plr, self.Whitelist)
		self.Relay.Blacklist = self:_updateListForPlayer(Plr, self.Blacklist)
		self:awaitPlayerDataAsync(Plr)
		local mockPath = Util:getDataStringPath(Plr, true) .. "." .. stringPath
		local lastValue = self:fetch(Plr, stringPath)

		if typeof(value) == "function" then
			value = value(lastValue)
		end

		local result
		if useMock then
			result = self.Relay:setValueFromStringIndex(Plr, mockPath, value, fromClient)
		else
			local path = Util:getDataStringPath(Plr) .. "." .. stringPath
			result = self.Relay:setValueFromStringIndex(Plr, path, value, fromClient)

			self.Relay:setValueFromStringIndex(Plr, mockPath, value, fromClient) -- sync with mock
		end
		if result then
			if self._changedSignals[mockPath] then
				self._changedSignals[mockPath]:Fire(Player, lastValue, value)
			end
			self:_buildLeaderstats(Plr)
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

--[=[
Removes a player's data from the profile store using their UserId.

@param UserID number -- The UserId of the player whose data should be removed

@error RUN_ERR -- Occurs if game instance isn't running on studio
@return nil
]=]
function DataService:removeData(UserID: number)
	assert(RunService:IsStudio() and RunService:IsRunning(), Util.RUN_ERR)

	self._profileStore:RemoveAsync(UserID)
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
	local mockProfile = self._profileStore.Mock:StartSessionAsync(`{Player.UserId}`)
	local mockData = Sift.Dictionary.mergeDeep(mockProfile.Data, self.mockTemplate)
	mockProfile.Data = mockData

	if profile then
		profile:AddUserId(Player.UserId)
		profile:Reconcile()

		profile.OnSessionEnd:Connect(function()
			self:cleanup()
			Player:Kick("Profile session end - please rejoin")
		end)

		if not (Player.Parent == Players) then
			profile:EndSession()
			mockProfile:EndSession()
		else
			Debug(`Successfully loaded {Player.Name}'s data`)
			self._profiles[tostring(Player.UserId)] = { live = profile, mock = mockProfile }
			self:_buildLeaderstats(Player)
			self.Relay:fire(Player, "SyncData", mockProfile.Data)
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
	if not profile then
		return
	end
	local _, live = nil, profile.live
	if live then
		Debug("Player data saved")
		live:EndSession()
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
