@allowed([
  'new'
  'existing'
])
param newOrExistingWorkspace string = 'new'

@description('The name of the Azure Databricks workspace to create. It must be between 3 and 64 characters long and can only contain alphanumeric characters, underscores (_), hyphens (-), and periods (.).')
@minLength(3)
@maxLength(64)
param databricksResourceName string

@description('Specifies whether to deploy Azure Databricks workspace with Secure Cluster Connectivity (No Public IP) enabled or not')
param disablePublicIp bool = false

@description('The pricing tier of workspace.')
@allowed([
  'standard'
  'premium'
])
param sku string = 'standard'

var deploymentId = guid(resourceGroup().id)
var deploymentIdShort = substring(deploymentId, 0, 8)
var acceleratorRepoName = 'databricks-accelerator-legend-getting-started'
var managedResourceGroupName = 'databricks-rg-${databricksResourceName}-${uniqueString(databricksResourceName, resourceGroup().id)}'
var trimmedMRGName = substring(managedResourceGroupName, 0, min(length(managedResourceGroupName), 90))
var managedResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', trimmedMRGName)

// Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'mi-${deploymentIdShort}'
  location: resourceGroup().location
}

// Create Databricks Workspace if `newOrExistingWorkspace` is 'new'
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

// Reference to an existing Databricks workspace if `newOrExistingWorkspace` is 'existing'
resource databricks 'Microsoft.Databricks/workspaces@2024-05-01' existing = if (newOrExistingWorkspace == 'existing') {
  name: databricksResourceName
}

// Role Assignment (Contributor Role)
resource databricksRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedIdentity.id, 'Contributor', databricks.id ?? newDatabricks.id)
  scope: databricks ?? newDatabricks
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor role ID
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
      set -e

      # Install Databricks CLI
      echo "Installing Databricks CLI..."
      curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

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

      # Clone repo and get ID
      echo "Cloning repo..."
      repo_info=$(databricks repos create https://github.com/southworks/${ACCELERATOR_REPO_NAME} gitHub)
      REPO_ID=$(echo "$repo_info" | jq -r '.id')
      databricks repos update ${REPO_ID} --branch ${BRANCH_NAME}

      # Download Legend JAR and upload to DBFS
      echo "Downloading Legend JAR from GitHub..."
      jar_url="https://raw.githubusercontent.com/southworks/${ACCELERATOR_REPO_NAME}/${BRANCH_NAME}/deploy-azure/employee-model-entities-0.0.1-SNAPSHOT.jar"
      if ! curl -L "$jar_url" -o legend.jar; then
        echo "Failed to download Legend JAR from GitHub"
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

      # Export job-template.json from workspace
      databricks workspace export /Users/${ARM_CLIENT_ID}/${ACCELERATOR_REPO_NAME}/deploy-azure/job-template.json > job-template.json
      notebook_path="/Users/${ARM_CLIENT_ID}/${ACCELERATOR_REPO_NAME}/RUNME"
      jq ".tasks[0].notebook_task.notebook_path = \"${notebook_path}\"" job-template.json > job.json

      # Create and run job
      job_page_url=$(databricks jobs submit --json @./job.json | jq -r '.run_page_url')
      echo "{\"job_page_url\": \"$job_page_url\"}" > $AZ_SCRIPTS_OUTPUT_PATH
      '''
    environmentVariables: [
      {
        name: 'DATABRICKS_AZURE_RESOURCE_ID'
        value: databricks.id ?? newDatabricks.id
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
      {
        name: 'BRANCH_NAME'
        value: 'add-job-template-runme'
      }
    ]
    timeout: 'PT1H'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'PT2H'
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
output databricksWorkspaceUrl string = 'https://${(databricks ?? newDatabricks).properties.workspaceUrl}'
output databricksJobUrl string = deploymentScript.properties.outputs.job_page_url
