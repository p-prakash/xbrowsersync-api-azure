# xBrowserSync Serverless API on Azure

This is a simple implementation of [xBrowserSync API](https://github.com/xbrowsersync/api) using Azure Serverless technologies. All the components that's used here are on-demand hence you pay only for what you use.

### Prerequisites
* Active Azure Subscription
* Azure AD permissions to create RBAC Role, CosmosDB, API Managment, Azure functions, Storage Account and other dependent services.

### Deployment
Run the following [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) command to deploy this API backend using [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/overview).


Login to Azure CLI:
```
az login
```

If you have multiple subscription configure the CLI to use specific subscription
```
az account set -s <Subscription name or Id>
```

Deploy the API from the Bicep template (*Change the location to approriate location as needed*)
```
az deployment sub create --location westeurope --template-file .\main.bicep
```
