targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('azd environment name — used as suffix on resource names')
param environmentName string

@minLength(1)
@description('Azure region for all resources (e.g. eastus2)')
param location string

@description('Azure OpenAI API version')
param aoaiApiVersion string = '2024-10-21'

@description('Model to deploy in Azure OpenAI')
param aoaiModelName string = 'gpt-5-mini'

@description('Model version to deploy')
param aoaiModelVersion string = '2025-08-07'

@description('Capacity (thousands of TPM) for the model deployment')
param aoaiDeploymentCapacity int = 50

@description('Comma-separated allowlist of origins permitted to call the proxy')
param allowedOrigins string = 'https://microsoft.github.io,https://jordankingisalive.github.io'

@description('Per-IP requests per rolling hour')
param rateLimitPerHour string = '15'

@description('Max output tokens per LLM call')
param maxTokens string = '800'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location:               location
    resourceToken:          resourceToken
    tags:                   tags
    aoaiApiVersion:         aoaiApiVersion
    aoaiModelName:          aoaiModelName
    aoaiModelVersion:       aoaiModelVersion
    aoaiDeploymentCapacity: aoaiDeploymentCapacity
    allowedOrigins:         allowedOrigins
    rateLimitPerHour:       rateLimitPerHour
    maxTokens:              maxTokens
  }
}

output RESOURCE_GROUP_NAME       string = rg.name
output FUNCTION_APP_NAME         string = resources.outputs.functionAppName
output FUNCTION_APP_URL          string = resources.outputs.functionAppUrl
output FUNCTION_CHAT_ENDPOINT    string = resources.outputs.functionChatEndpoint
output APPLICATIONINSIGHTS_NAME  string = resources.outputs.appInsightsName
output AOAI_ACCOUNT_NAME         string = resources.outputs.aoaiAccountName
output AOAI_ENDPOINT             string = resources.outputs.aoaiEndpoint
output AOAI_DEPLOYMENT           string = resources.outputs.aoaiDeploymentName
