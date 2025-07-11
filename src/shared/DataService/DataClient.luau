local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Relay = require(ReplicatedStorage.Shared.Relay)
local Util = require(script.Parent.DataUtil)

local Sift = require(ReplicatedStorage.Packages.Sift)

--[=[
DataService client handles syncing data with the client and providing useful tools to detect changes in data etc

@class DataServiceClient 
@client
]=]
local DataServiceClient = {
	_profile = {},
	_DEBUG = RunService:IsStudio(),
	started = false,
}

--[=[
Utility function to log debug messages using a specified output method.

@param Message string -- The debug message to output
@param Method any? -- (Optional) A custom method to handle the message output; defaults to `print`

@within DataServiceClient
@ignore
@return nil
]=]
local function Debug(Message: string, Method: any?)
	Method = Method or print
	Method(Message)
end

--[=[
Constructs the full server-side data path for the local player by appending a relative string path.

@param stringPath string -- The relative string path to append to the player's data path

@within DataServiceClient
@ignore
@return string -- The full string path used to access the player's data on the server
]=]
local function getServerPath(stringPath: string)
	return Util:getDataStringPath(Players.LocalPlayer) .. "." .. stringPath
end

--[=[
Initializes the DataServiceClient by creating a new Relay client instance.

@within DataServiceClient
@return nil
]=]
function DataServiceClient:init()
	self.Relay = Relay.client.new("DataService@1.0", self)
end

--[=[
Returns a signal that fires when the data at the specified string path changes.

@param stringPath string -- The string path representing the location of the data to watch for changes

@within DataServiceClient
@return Signal -- A signal that fires when the specified data changes
]=]
function DataServiceClient:getDataChangedSignal(stringPath: string)
	local clientPath = "_profile" .. "." .. stringPath
	return self.Relay:getServerChangedSignal(clientPath)
end

--[=[
Synchronizes the client's local profile data with new data from the server.
⚠️ This function should NOT be used as it is called automatically when the player joins.

@param Data {} -- The new data to sync with the client's profile

@within DataServiceClient
@return nil
]=]
function DataServiceClient:SyncData(mockData: {})
	Debug("Successfully synced server data with the client")
	self._profile = mockData
	self.started = true
end

function DataServiceClient:waitForSync()
	if not self.started then
		repeat
			task.wait()
		until self.started
	end
end

--[=[
Sets server data asynchronously to the given string path.

@param stringPath string -- The string path representing the location where the data should be posted
@param value any? -- The value to post to the specified path; can be nil

@within DataServiceClient
@return nil
]=]
function DataServiceClient:postDataAsync(stringPath: string, value: any?)
	self.Relay:postDataAsync(getServerPath(stringPath), value)
end

--[=[
Fetches data asynchronously from the given string path from the server.

@param stringPath string -- The string path representing the location of the data to fetch
@param awaitSync boolean? -- Whether or not the function should yield until the data is loaded

@within DataServiceClient
@return any? -- The data retrieved from the specified path
]=]
function DataServiceClient:fetch(stringPath: string, awaitSync: boolean?)
	if awaitSync ~= false then
		self:waitForSync()
	end
	local path, lastKey = Relay.util:getIndexValueFromString(stringPath, self._profile)
	return path[lastKey]
end

return DataServiceClient
