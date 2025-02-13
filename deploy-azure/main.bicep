@allowed([
  'new'
  'existing'
])
param newOrExistingWorkspace string = 'new'

@description('The name of the Azure Databricks workspace to create.')
param databricksResourceName string

@description('Specifies whether to deploy Azure Databricks workspace with Secure Cluster Connectivity (No Public IP) enabled or not')
param disablePublicIp bool = false

@description('The pricing tier of workspace.')
@allowed([
  'standard'
  'premium'
])
param sku string = 'standard'

// Variables
var deploymentId = guid(resourceGroup().id)
var deploymentIdShort = substring(deploymentId, 0, 8)
var managedResourceGroupName = 'databricks-rg-${databricksResourceName}-${uniqueString(databricksResourceName, resourceGroup().id)}'
var trimmedMRGName = substring(managedResourceGroupName, 0, min(length(managedResourceGroupName), 90))
var managedResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', trimmedMRGName)

// Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  name: 'dbw-id-${deploymentIdShort}'
  location: resourceGroup().location
}

// Databricks Workspace
resource newDatabricks 'Microsoft.Databricks/workspaces@2024-05-01' = if (newOrExistingWorkspace == 'new') {
  name: databricksResourceName
  location: resourceGroup().location
  sku: {
    name: sku
  }
  properties: {
    managedResourceGroupId: managedResourceGroupId
    parameters: {
      enableNoPublicIp: {
        value: disablePublicIp
      }
    }
  }
}

resource databricks 'Microsoft.Databricks/workspaces@2024-09-01-preview' existing = {
  name: databricksResourceName
  dependsOn: newOrExistingWorkspace == 'new' ? [newDatabricks] : []
}

// Role Assignment
resource databricksRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedIdentity.id, 'Contributor', databricks.id)
  scope: databricks
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Deployment Script
resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'setup-databricks-script'
  location: resourceGroup().location
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.9.1'
    scriptContent: '''
      set -x  # Enable command tracing

      cd ~
      echo "Starting script execution..."

      # Install Databricks CLI
      echo "Installing Databricks CLI..."
      if ! curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh; then
        echo "Failed to install Databricks CLI"
        exit 1
      fi

      echo "Databricks CLI installed successfully"
      which databricks || echo "databricks command not found"
      databricks version || echo "Failed to get version"

      # Configure Databricks CLI
      echo "Configuring Databricks CLI..."
      config_content="[DEFAULT]
host = https://${DATABRICKS_HOST}
azure_workspace_resource_id = ${DATABRICKS_AZURE_RESOURCE_ID}
auth_type = azure-cli"

      echo "$config_content" > ~/.databrickscfg

      # Test connection
      echo "Testing Databricks connection..."
      if ! databricks workspace list / --output json; then
        echo "Failed to connect to Databricks workspace"
        echo "Debug information:"
        ls -la ~/.databrickscfg
        cat ~/.databrickscfg
        echo "Environment variables:"
        env | grep -i databricks
        exit 1
      fi

      echo "Successfully connected to Databricks workspace"

      # Attempt to create cluster
      echo "Creating cluster..."
      cluster_config='{
        "cluster_name": "legend-cluster",
        "spark_version": "10.4.x-scala2.12",
        "node_type_id": "Standard_DS3_v2",
        "num_workers": 1,
        "spark_conf": {
          "spark.serializer": "org.apache.spark.serializer.KryoSerializer"
        },
        "autotermination_minutes": 120
      }'

      echo "Cluster configuration:"
      echo "$cluster_config"

      # Create cluster and capture output
      cluster_response=$(databricks clusters create --json "$cluster_config")
      create_status=$?

      echo "Cluster creation response:"
      echo "$cluster_response"

      if [ $create_status -ne 0 ]; then
        echo "Failed to create cluster"
        exit 1
      fi

      echo "Script completed successfully"
    '''
    environmentVariables: [
      {
        name: 'DATABRICKS_AZURE_RESOURCE_ID'
        value: databricks.id
      }
      {
        name: 'DATABRICKS_HOST'
        value: databricks.properties.workspaceUrl
      }
      {
        name: 'ARM_CLIENT_ID'
        value: managedIdentity.properties.clientId
      }
      {
        name: 'ARM_USE_MSI'
        value: 'true'
      }
    ]
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'PT1H'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  dependsOn: [
    databricksRoleAssignment
  ]
}
