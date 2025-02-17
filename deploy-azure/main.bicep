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
var acceleratorRepoName = 'databricks-accelerator-legend-getting-started'

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

      # Create new single-node cluster
      echo "Creating new cluster..."
      cluster_config='{
        "num_workers": 0,
        "cluster_name": "legend-cluster",
        "spark_version": "10.4.x-scala2.12",
        "spark_conf": {
          "spark.master": "local[*, 4]",
          "spark.databricks.cluster.profile": "singleNode"
        },
        "azure_attributes": {
          "first_on_demand": 1,
          "availability": "ON_DEMAND_AZURE",
          "spot_bid_max_price": -1
        },
        "node_type_id": "Standard_DS3_v2",
        "driver_node_type_id": "Standard_DS3_v2",
        "ssh_public_keys": [],
        "custom_tags": {
          "ResourceClass": "SingleNode"
        },
        "spark_env_vars": {},
        "autotermination_minutes": 120,
        "enable_elastic_disk": true,
        "init_scripts": [],
        "enable_local_disk_encryption": false,
        "data_security_mode": "NONE",
        "runtime_engine": "STANDARD"
      }'

      cluster_response=$(databricks clusters create --json "$cluster_config")
      cluster_id=$(echo "$cluster_response" | jq -r '.cluster_id')
      echo "Created new cluster with ID: $cluster_id"

      # Clone repo and get ID
      echo "Cloning repo..."
      repo_url="https://github.com/southworks/${ACCELERATOR_REPO_NAME}"
      repo_response=$(databricks repos create "$repo_url" github)
      repo_id=$(echo "$repo_response" | jq -r '.id')
      echo "Created repo with ID: $repo_id"

      if [ -z "$repo_id" ]; then
        echo "Failed to get repo ID"
        exit 1
      fi

      # Switch to accelerator-updates branch and wait for update
      echo "Switching to accelerator-updates branch..."
      if ! databricks repos update "$repo_id" --branch accelerator-updates; then
        echo "Failed to switch branch"
        exit 1
      fi

      # Wait for repo to update and verify branch
      echo "Waiting for repo to update..."
      sleep 10
      repo_info=$(databricks repos get "$repo_id")
      current_branch=$(echo "$repo_info" | jq -r '.branch')
      echo "Current branch: $current_branch"

      if [ "$current_branch" != "accelerator-updates" ]; then
        echo "Failed to switch to accelerator-updates branch"
        exit 1
      fi

      # Create DBFS directories
      echo "Creating DBFS directories..."
      if ! databricks fs mkdirs dbfs:/FileStore/legend/data/; then
        echo "Failed to create data directory"
        exit 1
      fi

      if ! databricks fs mkdirs dbfs:/FileStore/legend/jars/; then
        echo "Failed to create jars directory"
        exit 1
      fi

      # Export mock data from workspace and upload to DBFS
      echo "Exporting mock data from workspace..."
      if ! databricks workspace export "/Users/${ARM_CLIENT_ID}/${ACCELERATOR_REPO_NAME}/notebooks/data/MOCK_DATA.json" > mock_data.json; then
        echo "Failed to export mock data from workspace"
        exit 1
      fi

      echo "Uploading to DBFS..."
      if ! databricks fs cp mock_data.json dbfs:/FileStore/legend/data/MOCK_DATA.json; then
        echo "Failed to upload mock data to DBFS"
        exit 1
      fi

      # Download JAR and upload to DBFS
      echo "Downloading JAR from GitHub..."
      jar_url="https://raw.githubusercontent.com/southworks/${ACCELERATOR_REPO_NAME}/accelerator-updates/deploy-azure/employee-model-entities-0.0.1-SNAPSHOT.jar"
      if ! curl -L "$jar_url" -o legend.jar; then
        echo "Failed to download JAR from GitHub"
        exit 1
      fi

      echo "Creating DBFS directories..."
      databricks fs mkdirs "dbfs:/FileStore"
      databricks fs mkdirs "dbfs:/FileStore/legend"
      databricks fs mkdirs "dbfs:/FileStore/legend/jars"

      echo "Uploading JAR to DBFS..."
      if ! databricks fs cp "legend.jar" "dbfs:/FileStore/legend/jars/employee-model-entities-0.0.1-SNAPSHOT.jar"; then
        echo "Failed to upload JAR to DBFS"
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
          },
          {
            "maven": {
              "coordinates": "org.finos.legend-community:legend-delta:0.1.10"
            }
          },
          {
            "jar": "dbfs:/FileStore/legend/jars/employee-model-entities-0.0.1-SNAPSHOT.jar"
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
      {
        name: 'ACCELERATOR_REPO_NAME'
        value: acceleratorRepoName
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
