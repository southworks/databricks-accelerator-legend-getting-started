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
      cd ~

      # Install Databricks CLI
      echo "Installing Databricks CLI..."
      curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

      # Configure Databricks CLI
      echo "Configuring Databricks CLI..."
      cat << EOF > ~/.databrickscfg
      [DEFAULT]
      host = https://${DATABRICKS_HOST}
      azure_workspace_resource_id = ${DATABRICKS_AZURE_RESOURCE_ID}
      auth_type = azure-cli
      EOF

      # Verify configuration
      echo "Verifying Databricks CLI configuration..."
      databricks configure list

      # Create cluster
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

      cluster_id=$(databricks clusters create --json "$cluster_config" | jq -r '.cluster_id')
      echo "Created cluster with ID: $cluster_id"

      # Install libraries
      echo "Installing libraries..."
      libraries_config='{
        "libraries": [
          {
            "maven": {
              "coordinates": "org.finos.legend-community:legend-delta:0.1.10"
            }
          },
          {
            "pypi": {
              "package": "legend-delta==0.1.10"
            }
          },
          {
            "pypi": {
              "package": "PyYAML==6.0.2"
            }
          }
        ]
      }'

      databricks libraries install --cluster-id "$cluster_id" --json "$libraries_config"

      # Create directories
      echo "Creating directories..."
      databricks workspace mkdirs /legend
      databricks fs mkdirs dbfs:/legend/data

      # Upload Legend JAR
      echo "Uploading Legend JAR..."
      databricks fs cp employee-model-entities-0.0.1-SNAPSHOT.jar dbfs:/legend/jars/
      databricks libraries install --cluster-id "$cluster_id" --jar "dbfs:/legend/jars/employee-model-entities-0.0.1-SNAPSHOT.jar"

      # Upload notebook and data
      echo "Uploading notebook and data..."
      databricks workspace import 01_legend_delta.py /legend/01_legend_delta --language PYTHON --format SOURCE
      databricks fs cp MOCK_DATA.json dbfs:/legend/data/

      # Save cluster ID for output
      echo "{\"clusterId\":\"$cluster_id\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
    environmentVariables: [
      {
        name: 'DATABRICKS_AZURE_RESOURCE_ID'
        value: databricks.id
      }
      {
        name: 'DATABRICKS_HOST'
        value: 'adb-${databricks.properties.workspaceUrl}'
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

// Outputs
output databricksWorkspaceUrl string = 'https://${databricks.properties.workspaceUrl}'
output clusterUrl string = 'https://${databricks.properties.workspaceUrl}/#setting/clusters/${deploymentScript.properties.outputs.clusterId}/configuration'
