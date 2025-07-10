--[=[
Stores useful strings/functions

@class DataUtil
]=]
local Util = {
	STANDARD_ERR = "Please follow the correct documentation for DataService. Error Code: ",
	BOOT_ERR = "Failed to run method: service has not been initialized yet",
	RUN_ERR = "Attempted to call a function that may only be called in studio",
}

--[=[
Retrieves the string path to the data section of the given player's profile for replication purposes.
Example:
```lua
print(getDataStringPath(Player)) -> "_profiles.414941613.live.Data"
```

@param Player Player -- The player whose data string path you want to retrieve

@within DataUtil
@return string -- The string path pointing to the player's data in the profile system
]=]
function Util:getDataStringPath(Player: Player, Mock: boolean?)
	return `_profiles.{Player.UserId}.{Mock and "mock" or "live"}`
end

Util.Enums = {
	LOCAL_PATH = "_profile",
}

return Util
