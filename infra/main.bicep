// =====================================================================
// Cloud Resume Challenge - IaC genérico e reutilizável
// Pode ser implantado em qualquer Resource Group novo/vazio.
// =====================================================================

@description('Prefixo curto para nomear os recursos (ex: henriqueresume)')
@minLength(3)
@maxLength(11)
param namePrefix string

@description('Localização dos recursos')
param location string = resourceGroup().location

@description('Domínio customizado (ex: resume.seudominio.com)')
param customDomainName string

// Sufixo único e determinístico, baseado no RG - garante nomes globais únicos
// sem depender de valores "sorteados" pelo Azure após a criação.
var uniqueSuffix = uniqueString(resourceGroup().id)
var storageSuffix = substring(uniqueSuffix, 0, 8) // nomes de Storage Account têm limite de 24 caracteres
var siteStorageName = '${namePrefix}site${storageSuffix}'
var funcStorageName = '${namePrefix}func${storageSuffix}'
var cosmosName = '${namePrefix}db${uniqueSuffix}'
var functionAppName = '${namePrefix}-api-${uniqueSuffix}'
var frontDoorProfileName = '${namePrefix}-fd-${uniqueSuffix}'

// ---------------------------------------------------------------------
// Storage Account - site estático
// ---------------------------------------------------------------------
resource siteStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: siteStorageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: true
    supportsHttpsTrafficOnly: true
  }
}

resource siteStorageBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: siteStorage
  name: 'default'
}

// LIMITAÇÃO CONHECIDA DO BICEP (confirmada via erro BCP037):
// O schema tipado do Bicep não expõe a propriedade "staticWebsite", mesmo
// ela existindo na API REST/ARM JSON. É uma lacuna do type-schema do Bicep,
// não uma limitação da plataforma Azure em si. Solução usada pela comunidade
// (e por este projeto): habilitar via Azure CLI, no pipeline de CI/CD, logo
// após o `az deployment group create`:
//   az storage blob service-properties update --account-name <siteStorageName> \
//     --static-website --index-document index.html --404-document index.html

// ---------------------------------------------------------------------
// Cosmos DB - Table API Serverless
// ---------------------------------------------------------------------
resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    capabilities: [
      { name: 'EnableTable' }
      { name: 'EnableServerless' }
    ]
    databaseAccountOfferType: 'Standard'
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: false }
    ]
  }
}

resource cosmosTable 'Microsoft.DocumentDB/databaseAccounts/tables@2024-05-15' = {
  parent: cosmosDb
  name: 'Counter'
  properties: { resource: { id: 'Counter' } }
}

// ---------------------------------------------------------------------
// Storage dedicado ao runtime da Function (Flex Consumption exige)
// ---------------------------------------------------------------------
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: funcStorageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource funcStorageBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: funcStorage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: funcStorageBlobService
  name: 'deploymentpackage'
}

// ---------------------------------------------------------------------
// Application Insights
// ---------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs-${uniqueSuffix}'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai-${uniqueSuffix}'
  location: location
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: logAnalytics.id }
}

// ---------------------------------------------------------------------
// Function App - Flex Consumption (Linux, Python)
// ---------------------------------------------------------------------
resource flexPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-plan-${uniqueSuffix}'
  location: location
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: flexPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${funcStorage.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      runtime: { name: 'python', version: '3.12' }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};AccountKey=${funcStorage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};AccountKey=${funcStorage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          // Em produção real: trocar por Key Vault Reference.
          name: 'COSMOS_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${cosmosDb.name};AccountKey=${cosmosDb.listKeys().primaryMasterKey};TableEndpoint=https://${cosmosDb.name}.table.cosmos.azure.com:443/;'
        }
      ]
      cors: { allowedOrigins: ['https://${customDomainName}'] }
    }
  }
}

// ---------------------------------------------------------------------
// Front Door Standard - CDN/HTTPS
// ---------------------------------------------------------------------
resource frontDoor 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: frontDoorProfileName
  location: 'global'
  sku: { name: 'Standard_AzureFrontDoor' }
}

resource fdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: frontDoor
  name: '${namePrefix}-${uniqueSuffix}'
  location: 'global'
  properties: { enabledState: 'Enabled' }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: frontDoor
  name: 'origin-group-site'
  properties: {
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3 }
    healthProbeSettings: { probePath: '/', probeRequestType: 'HEAD', probeProtocol: 'Http', probeIntervalInSeconds: 100 }
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: originGroup
  name: 'site-origin'
  properties: {
    hostName: replace(replace(siteStorage.properties.primaryEndpoints.web, 'https://', ''), '/', '')
    httpPort: 80
    httpsPort: 443
    originHostHeader: replace(replace(siteStorage.properties.primaryEndpoints.web, 'https://', ''), '/', '')
    priority: 1
    weight: 1000
  }
}

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: fdEndpoint
  name: 'route-site'
  properties: {
    originGroup: { id: originGroup.id }
    supportedProtocols: ['Http', 'Https']
    patternsToMatch: ['/*']
    forwardingProtocol: 'MatchRequest'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
  }
  dependsOn: [origin]
}

// ---------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------
output siteStorageWebEndpoint string = siteStorage.properties.primaryEndpoints.web
output frontDoorHostName string = fdEndpoint.properties.hostName
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}/api/counter'
