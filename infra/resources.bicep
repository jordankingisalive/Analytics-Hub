param location string
param resourceToken string
param tags object

param aoaiApiVersion string
param aoaiModelName string
param aoaiModelVersion string
param aoaiDeploymentCapacity int
param allowedOrigins string
param rateLimitPerHour string
param maxTokens string

// ---------------- Azure OpenAI ----------------
resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'aoai-ahcop-${resourceToken}'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: 'aoai-ahcop-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource aoaiDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: aoaiModelName
  sku: {
    name: 'GlobalStandard'
    capacity: aoaiDeploymentCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: aoaiModelName
      version: aoaiModelVersion
    }
  }
}

// ---------------- Storage (required by Functions) ----------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stahcop${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------- Observability ----------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-ahcop-${resourceToken}'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-ahcop-${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------------- Linux Consumption plan (Y1) ----------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-ahcop-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Linux
  }
}

// ---------------- Function App ----------------
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'func-ahcop-${resourceToken}'
  location: location
  tags: union(tags, { 'azd-service-name': 'api' })
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|20'
      minTlsVersion: '1.2'
      ftpsState: 'FtpsOnly'
      http20Enabled: true
      cors: {
        // CORS is enforced inside the Function (Access-Control headers in code)
        // but we set this so the Functions host doesn't strip the OPTIONS verb.
        allowedOrigins: [ '*' ]
        supportCredentials: false
      }
      appSettings: [
        { name: 'AzureWebJobsStorage',              value: storageConnectionString }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: storageConnectionString }
        { name: 'WEBSITE_CONTENTSHARE',             value: 'func-ahcop-${resourceToken}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',      value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',         value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION',     value: '~20' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'AOAI_ENDPOINT',                    value: aoai.properties.endpoint }
        { name: 'AOAI_KEY',                         value: aoai.listKeys().key1 }
        { name: 'AOAI_DEPLOYMENT',                  value: aoaiDeployment.name }
        { name: 'AOAI_API_VERSION',                 value: aoaiApiVersion }
        { name: 'ALLOWED_ORIGINS',                  value: allowedOrigins }
        { name: 'RATE_LIMIT_PER_HOUR',              value: rateLimitPerHour }
        { name: 'MAX_TOKENS',                       value: maxTokens }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT',   value: 'true' }
        { name: 'ENABLE_ORYX_BUILD',                value: 'true' }
      ]
    }
  }
}

output functionAppName        string = functionApp.name
output functionAppUrl         string = 'https://${functionApp.properties.defaultHostName}'
output functionChatEndpoint   string = 'https://${functionApp.properties.defaultHostName}/api/chat'
output appInsightsName        string = appInsights.name
output aoaiAccountName        string = aoai.name
output aoaiEndpoint           string = aoai.properties.endpoint
output aoaiDeploymentName     string = aoaiDeployment.name
