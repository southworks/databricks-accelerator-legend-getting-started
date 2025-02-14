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
var location = resourceGroup().location

// Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  name: 'dbw-id-${deploymentIdShort}'
  location: location
}

// Databricks Workspace
resource newDatabricks 'Microsoft.Databricks/workspaces@2024-05-01' = if (newOrExistingWorkspace == 'new') {
  name: databricksResourceName
  location: location
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
  location: location
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

      # Test connection and wait for storage initialization
      echo "Testing connection and waiting for storage initialization..."
      max_attempts=30
      attempt=0
      while [ $attempt -lt $max_attempts ]; do
        if databricks fs ls dbfs:/; then
          echo "Storage initialized successfully"
          break
        fi
        echo "Waiting for storage initialization... (attempt $((attempt + 1)))"
        sleep 10
        attempt=$((attempt + 1))
      done

      if [ $attempt -eq $max_attempts ]; then
        echo "Timeout waiting for storage initialization"
        exit 1
      fi

      # Check and delete existing cluster
      echo "Checking for existing legend-cluster..."
      existing_cluster=$(databricks clusters list --output json | jq -r '.clusters[] | select(.cluster_name == "legend-cluster") | .cluster_id')
      if [ ! -z "$existing_cluster" ]; then
        echo "Found existing cluster. Deleting..."
        databricks clusters permanent-delete --cluster-id "$existing_cluster"
        sleep 10
      fi

      # Create new single-node cluster
      echo "Creating new cluster..."
      cluster_config='{
        "cluster_name": "legend-cluster",
        "spark_version": "10.4.x-scala2.12",
        "node_type_id": "Standard_DS3_v2",
        "spark_conf": {
          "spark.serializer": "org.apache.spark.serializer.KryoSerializer",
          "spark.master": "local[*]",
          "spark.databricks.cluster.profile": "singleNode"
        },
        "custom_tags": {
          "ResourceClass": "SingleNode"
        },
        "spark_env_vars": {
          "PYSPARK_PYTHON": "/databricks/python3/bin/python3"
        },
        "num_workers": 0,
        "autotermination_minutes": 120
      }'

      cluster_response=$(databricks clusters create --json "$cluster_config")
      cluster_id=$(echo "$cluster_response" | jq -r '.cluster_id')
      echo "Created new cluster with ID: $cluster_id"

      # Clone repo
      echo "Cloning repo..."
      repo_url="https://github.com/southworks/databricks-accelerator-legend-getting-started"
      if ! databricks repos create "$repo_url" github; then
        echo "Failed to clone repo"
        exit 1
      fi

      # Install libraries
      echo "Installing libraries..."
      libraries_config='{
        "cluster_id": "'$cluster_id'",
        "libraries": [
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

      if ! databricks libraries install --json "$libraries_config"; then
        echo "Failed to install libraries"
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

output databricksWorkspaceUrl string = 'https://${databricks.properties.workspaceUrl}'
