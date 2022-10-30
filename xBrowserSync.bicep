@description('Name of the API environment')
param apiEnv string = 'prod'

@description('Primary Azure region to be used')
param location string

@description('Using UUID to generate unique password hash')
param guidValue string

var prefix = substring(uniqueString(resourceGroup().id), 0, 6)
var databaseName = 'xBrowserSyncDB-${prefix}'
var containerName = 'xBrowserSyncContainer-${prefix}'
var functionKey = base64('${guidValue}${uniqueString(resourceGroup().id)}')

resource dbAccount 'Microsoft.DocumentDB/databaseAccounts@2022-08-15' = {
  name: 'xbrowsersync-${toLower(prefix)}'
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
    backupPolicy: {
      type: 'Continuous'
    }
    enableAutomaticFailover: true
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2022-08-15' = {
  name: databaseName
  parent: dbAccount
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource dbContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2022-08-15' = {
  name: containerName
  parent: database
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          '/id'
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/_etag/?'
          }
        ]
      }
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: 'xbrowsersync${toLower(prefix)}'
  location: location
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource serverFarm 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: 'xBrowserSync-${toLower(prefix)}'
  location: location
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource logAnalyticsWksp 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'xBrowserSync-workspace-${prefix}'
  location: location
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: 30
    sku: {
      name: 'pergb2018'
    }
    workspaceCapping: {
      dailyQuotaGb: -1
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'xBrowserSync-${prefix}'
  location: location
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    Request_Source: 'rest'
    RetentionInDays: 30
    WorkspaceResourceId: logAnalyticsWksp.id
  }
}

resource xBrowserSyncFunctionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: 'xBrowserSyncFunctionApp-${prefix}'
  location: location
  kind: 'functionapp,linux'
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    clientAffinityEnabled: false
    serverFarmId: serverFarm.id
    enabled: true
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value}'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: 'InstrumentationKey=${appInsights.properties.InstrumentationKey}'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'RESOURCE_GROUP'
          value: resourceGroup().name
        }
        {
          name: 'DATABASE_ACCOUNT_NAME'
          value: dbAccount.name
        }
        {
          name: 'DATABASE_CONTAINER'
          value: dbContainer.name
        }
        {
          name: 'DATABASE_NAME'
          value: database.name
        }
        {
          name: 'DATABASE_URL'
          value: dbAccount.properties.documentEndpoint
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower('xBrowserSyncFunctionApp-${prefix}')
        }
      ]
      linuxFxVersion: 'Python|3.9'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

resource xBrowserSyncFunction 'Microsoft.Web/sites/functions@2022-03-01' = {
  name: 'xBrowserSync-${prefix}'
  parent: xBrowserSyncFunctionApp
  properties: {
    config: {
      disabled: false
      scriptFile: 'main.py'
      entryPoint: 'main'
      bindings: [
        {
          name: 'req'
          authLevel: 'function'
          type: 'httpTrigger'
          direction: 'in'
          methods: [
            'post'
            'put'
            'get'
          ]
        }
        {
          name: '$return'
          type: 'http'
          direction: 'out'
        }
      ]
    }
    files: {
      'main.py': loadTextContent('xbrowsersync_backend/main.py')
    }
    isDisabled: false
    language: 'python'
  }
}

resource xBrowserSyncFunctionKey 'Microsoft.Web/sites/functions/keys@2022-03-01' = {
  name: 'xBrowserSync-${prefix}-Key'
  parent: xBrowserSyncFunction
  properties :{
    name : 'xBrowserSync-API-Key'
    value: functionKey
  }  
}

var roleAssignmentId = guid('sql-role-assignment', resourceGroup().id, dbAccount.id)

resource dbRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-08-15' = {
  name: roleAssignmentId
  parent: dbAccount
  properties: {
    principalId: xBrowserSyncFunctionApp.identity.principalId
    roleDefinitionId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccount.name}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: dbAccount.id
  }
}

var functionRoleId = guid('xBrowserSync-Function-Role', resourceGroup().id, dbAccount.id)
var functionRoleAssignmentId = guid(functionRoleId, resourceGroup().id, dbAccount.id)

resource dbFunctionRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: functionRoleId
  properties: {
    assignableScopes: [
      resourceGroup().id
    ]
    description: 'Permission to access CosmosDB'
    permissions: [
      {
        actions: [
          'Microsoft.DocumentDB/databaseAccounts/read'
          'Microsoft.DocumentDB/databaseAccounts/listKeys/action'
          'Microsoft.DocumentDB/databaseAccounts/services/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/read'
          'Microsoft.DocumentDB/databaseAccounts/tables/read'
          'Microsoft.DocumentDB/operations/read'
        ]
        dataActions: []
        notActions: []
        notDataActions: []
      }
    ]
    roleName: functionRoleId
  }
}

resource dbFunctionRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: functionRoleAssignmentId
  properties: {
    description: 'Assigning the CosmosDB permissions to Function'
    principalId: xBrowserSyncFunctionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: dbFunctionRole.id
  }
}

resource xBrowserSyncApiMgmt 'Microsoft.ApiManagement/service@2021-12-01-preview' = {
  name: 'xBrowserSync-${prefix}-APIMgmt'
  location: location
  tags: {
    Reason: 'xBrowserSync'
    Environment: apiEnv
  }
  sku: {
    capacity: 0
    name: 'Consumption'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hostnameConfigurations: [
      {
        type: 'Proxy'
        hostName: '${toLower('xBrowserSync-${prefix}-APIMgmt')}.azure-api.net'
        negotiateClientCertificate: false
        defaultSslBinding: true
        certificateSource: 'BuiltIn'
      }
    ]
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'false'
    }
    disableGateway: false
    publisherEmail: 'no-reply@example.com'
    publisherName: 'Self Hosting'
    publicNetworkAccess: 'Enabled'
  }
}

resource apiNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-12-01-preview' = {
  name: 'xBrowserSync-${prefix}-Function-Key'
  parent: xBrowserSyncApiMgmt
  properties: {
    displayName: 'xBrowserSync-${prefix}-Function-Key'
    secret: true
    tags: [
      'xBrowserSync'
      'FunctionKey'
    ]
    value: functionKey
  }
}

resource apiBackend 'Microsoft.ApiManagement/service/backends@2021-12-01-preview' = { 
  name: 'xBrowserSync-${prefix}-Backend'
  parent: xBrowserSyncApiMgmt
  properties: {
    credentials: {
      header: {
        'x-functions-key': ['{{${apiNamedValue.name}}}']
      }
    }
    description: 'xBrowserSync Backend Function'
    protocol: 'http'
    resourceId: '${environment().resourceManager}${xBrowserSyncFunctionApp.id}'
    title: 'xBrowserSync-Backend-Function'
    url: 'https://${xBrowserSyncFunctionApp.properties.defaultHostName}/api'
    tls:{
      validateCertificateChain: false
      validateCertificateName: false
    }
  }
}

resource xBrowserSyncApi 'Microsoft.ApiManagement/service/apis@2021-12-01-preview' = {
  name: 'xBrowserSync-${prefix}-API'
  parent: xBrowserSyncApiMgmt
  properties: {
    apiType: 'http'
    description: 'xBrowserSync API'
    displayName: 'xBrowserSync API'
    isCurrent: true
    path: apiEnv
    protocols: [
      'https'
    ]
    serviceUrl: xBrowserSyncApiMgmt.properties.gatewayUrl
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
    subscriptionRequired: true
    type: 'http'
  }
}

resource xBrowserSyncApiLogger 'Microsoft.ApiManagement/service/loggers@2021-12-01-preview' = {
  name: 'xBrowserSync-${prefix}-API-Logger'
  parent: xBrowserSyncApiMgmt
  properties: {
    description: 'Log xBrowserSync API on Application Insights'
    isBuffered: true
    loggerType: 'applicationInsights'
    resourceId: appInsights.id
    credentials:{
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
  }
}

resource xBrowserSyncApiProduct 'Microsoft.ApiManagement/service/products@2021-12-01-preview' = {
  name: 'xBrowserSync-${prefix}-Product'
  parent: xBrowserSyncApiMgmt
  properties: {
    displayName: 'xBrowserSync'
    description: 'Backend API for xBrowserSync'
    subscriptionRequired: false
    state: 'published'
  }
}

resource xBrowserSyncApiProductMap 'Microsoft.ApiManagement/service/products/apis@2021-12-01-preview' = {
  name: '${xBrowserSyncApiMgmt.name}/${xBrowserSyncApiProduct.name}/${xBrowserSyncApi.name}'
}

resource xBrowserSyncApiSubscription 'Microsoft.ApiManagement/service/subscriptions@2021-12-01-preview' = {
  name: 'xBrowserSync-${prefix}-Subscription'
  parent: xBrowserSyncApiMgmt
  properties: {
    scope: '/apis/${xBrowserSyncApi.id}'
    displayName: 'All access subscription'
    state: 'active'
    allowTracing: true
  }
}

resource xBrowserSyncApiGetInfo 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'info'
  parent: xBrowserSyncApi
  properties: {
    description: 'xBrowserSync API'
    displayName: 'Info'
    method: 'GET'
    responses: [
      {
        description: 'Provide information about the API service'
        representations: [
          {
            contentType: 'application/json'
            examples: {
              default:{
                value: {
                  maxSyncSize: 1500000
                  message: 'Personal xBrowsersync API'
                  status: 1
                  version: '1.1.13' 
                }
              }
            }
          }
        ]
        statusCode: 200
      }
    ]
    urlTemplate: '/info'
  }
}

resource xBrowserSyncApiGetInfoPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: xBrowserSyncApiGetInfo
  name: 'policy'
  properties: {
    value: '<policies>\r\n  <inbound>\r\n    <base />\r\n    <mock-response status-code="200" content-type="application/json" />\r\n  </inbound>\r\n  <backend>\r\n    <base />\r\n  </backend>\r\n  <outbound>\r\n    <base />\r\n  </outbound>\r\n  <on-error>\r\n    <base />\r\n  </on-error>\r\n</policies>'
    format: 'xml'
  }
}

resource xBrowserSyncApiPostBookmarks 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'create-bookmarks'
  parent: xBrowserSyncApi
  properties: {
    description: 'API to create bookmarks'
    displayName: 'Create Bookmarks'
    method: 'POST'
    responses: [
      {
        description: 'Newly created sync Id, last updated time, and version'
        statusCode: 200
      }
    ]
    urlTemplate: '/bookmarks'
  }
}

resource xBrowserSyncApiPostBookmarksPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: xBrowserSyncApiPostBookmarks
  name: 'policy'
  properties: {
    value: '<policies>\r\n  <inbound>\r\n    <base/>\r\n    <set-backend-service id="apim-generated-policy" backend-id="${apiBackend.name}" />\r\n    <rewrite-uri template="/${xBrowserSyncFunction.name}"/>\r\n    <set-query-parameter name="uri" exists-action="override">\r\n      <value>/bookmarks</value>\r\n    </set-query-parameter>\r\n  </inbound>\r\n  <backend>\r\n    <base />\r\n  </backend>\r\n  <outbound>\r\n    <base />\r\n  </outbound>\r\n  <on-error>\r\n    <base />\r\n  </on-error>\r\n</policies>'
    format: 'rawxml'
  }
}

resource xBrowserSyncApiPutBookmarks 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'update-bookmarks'
  parent: xBrowserSyncApi
  properties: {
    description: 'API to update bookmarks'
    displayName: 'Update Bookmarks'
    method: 'PUT'
    templateParameters: [
      {
        name: 'id'
        required: true
        type: 'string'
      }
    ]
    responses: [
      {
        description: 'Last updated timestamp for corresponding bookmarks'
        statusCode: 200
      }
    ]
    urlTemplate: '/bookmarks/{id}'
  }
}

resource xBrowserSyncApiPutBookmarksPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: xBrowserSyncApiPutBookmarks
  name: 'policy'
  properties: {
    value: '<policies>\r\n  <inbound>\r\n    <base />\r\n    <set-backend-service id="apim-generated-policy" backend-id="${apiBackend.name}" />\r\n    <rewrite-uri template="/${xBrowserSyncFunction.name}" copy-unmatched-params="true" />\r\n    <set-query-parameter name="uri" exists-action="override">\r\n      <value>@(context.Request.OriginalUrl.Path.Trim(\'/\').Substring(context.Api.Path.Trim(\'/\').Length))</value>\r\n    </set-query-parameter>\r\n  </inbound>\r\n  <backend>\r\n    <base />\r\n  </backend>\r\n  <outbound>\r\n    <base />\r\n  </outbound>\r\n  <on-error>\r\n    <base />\r\n  </on-error>\r\n</policies>'
    format: 'xml'
  }
}

resource xBrowserSyncApiGetLastUpdated 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'last-updated-time'
  parent: xBrowserSyncApi
  properties: {
    description: 'API to get last updated time'
    displayName: 'Last Updated'
    method: 'GET'
    templateParameters: [
      {
        name: 'id'
        required: true
        type: 'string'
      }
    ]
    responses: [
      {
        description: 'Last updated timestamp for corresponding bookmarks'
        statusCode: 200
      }
    ]
    urlTemplate: '/bookmarks/{id}/lastUpdated'
  }
}

resource xBrowserSyncApiGetLastUpdatedpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: xBrowserSyncApiGetLastUpdated
  name: 'policy'
  properties: {
    value: '<policies>\r\n  <inbound>\r\n    <base />\r\n    <set-backend-service id="apim-generated-policy" backend-id="${apiBackend.name}" />\r\n    <rewrite-uri template="/${xBrowserSyncFunction.name}" copy-unmatched-params="true" />\r\n    <set-query-parameter name="uri" exists-action="override">\r\n      <value>@(context.Request.OriginalUrl.Path.Trim(\'/\').Substring(context.Api.Path.Trim(\'/\').Length))</value>\r\n    </set-query-parameter>\r\n  </inbound>\r\n  <backend>\r\n    <base />\r\n  </backend>\r\n  <outbound>\r\n    <base />\r\n  </outbound>\r\n  <on-error>\r\n    <base />\r\n  </on-error>\r\n</policies>'
    format: 'xml'
  }
}

resource xBrowserSyncApiGetVersion 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: 'get-version'
  parent: xBrowserSyncApi
  properties: {
    description: 'API to get the version'
    displayName: 'Get Version'
    method: 'GET'
    templateParameters: [
      {
        name: 'id'
        required: true
        type: 'string'
      }
    ]
    responses: [
      {
        description: 'Version number of the xBrowserSync client used to create the sync'
        statusCode: 200
      }
    ]
    urlTemplate: '/bookmarks/{id}/version'
  }
}

resource xBrowserSyncApiGetVersionPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  parent: xBrowserSyncApiGetVersion
  name: 'policy'
  properties: {
    value: '<policies>\r\n  <inbound>\r\n    <base />\r\n    <set-backend-service id="apim-generated-policy" backend-id="${apiBackend.name}" />\r\n    <rewrite-uri template="/${xBrowserSyncFunction.name}" copy-unmatched-params="true" />\r\n    <set-query-parameter name="uri" exists-action="override">\r\n      <value>@(context.Request.OriginalUrl.Path.Trim(\'/\').Substring(context.Api.Path.Trim(\'/\').Length))</value>\r\n    </set-query-parameter>\r\n  </inbound>\r\n  <backend>\r\n    <base />\r\n  </backend>\r\n  <outbound>\r\n    <base />\r\n  </outbound>\r\n  <on-error>\r\n    <base />\r\n  </on-error>\r\n</policies>'
    format: 'xml'
  }
}

resource xBrowserSyncApiDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2021-12-01-preview' = {
  parent: xBrowserSyncApiMgmt
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    logClientIp: true
    loggerId: xBrowserSyncApiLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        dataMasking: {
          queryParams: [
            {
              value: '*'
              mode: 'Hide'
            }
          ]
        }
      }
    }
    backend: {
      request: {
        dataMasking: {
          queryParams: [
            {
              value: '*'
              mode: 'Hide'
            }
          ]
        }
      }
    }
  }
}

resource xBrowserSyncServiceApiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2021-12-01-preview' = {
  parent: xBrowserSyncApi
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'Legacy'
    verbosity: 'information'
    logClientIp: true
    loggerId: xBrowserSyncApiLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
  }
}
