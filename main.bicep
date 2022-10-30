// Setting subscription as scope
targetScope = 'subscription'

// Parameters
@description('Name of the API environment')
param apiEnv string = 'prod'

@description('Azure Region where the API should be deployed')
param location string = 'westeurope'

param guidValue string = newGuid()
var prefix = uniqueString(guidValue)

// Create the resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'xBrowserSync-${prefix}'
  location: location
  tags: {
    Reason: 'xBrowserSync-${toLower(apiEnv)}'
    Environment: apiEnv
  }
}

// Create the xBrowserSync API backend using module
module stg './xBrowserSync.bicep' = {
  name: 'xBrowserSync-${prefix}'
  scope: rg    // Deployed in the scope of resource group we created above
  params: {
    apiEnv: apiEnv
    location: location
    guidValue: guidValue
  }
}

output guid string = guidValue
