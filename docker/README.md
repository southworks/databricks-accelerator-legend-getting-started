# Legend Local Setup Guide

This guide explains how to set up the Legend platform locally using WSL (Windows Subsystem for Linux) and Docker.

## Prerequisites

- Windows 10/11 with WSL installed
- Docker Desktop with WSL integration enabled
- GitLab account

## Initial Setup

### 1. WSL Configuration

1. Install Ubuntu on WSL (from PowerShell as administrator):
```powershell
wsl --install -d Ubuntu
```

2. Open Ubuntu and install required packages:
```bash
sudo apt-get update
sudo apt-get install git dos2unix
```

### 2. GitLab Configuration

1. Create a GitLab OAuth Application:
   - Go to GitLab > User Settings > Applications
   - Name: Legend Local
   - Add these redirect URIs:
     ```
     http://localhost:6060/callback
     http://localhost:7070/api/auth/callback
     http://localhost:7070/api/pac4j/login/callback
     http://localhost:8080/studio/log.in/callback
     http://localhost:9095/query/log.in/callback
     http://localhost:8076/depot-store/callback
     ```
   - Enable scopes: `openid`, `profile`, `api`
   - Check "Confidential"
   - Save application and note the Client ID and Secret

2. Create a GitLab Project:
   - Create a new project in GitLab
   - Note the Project ID (found in project's home page)

3. Create a Deploy Token:
   - Go to Project Settings > Repository > Deploy Tokens
   - Name: legend-deploy
   - Select scopes:
     - read_repository
     - read_package_registry
     - write_package_registry
   - Save token and note the username and token value

### 3. Repository Setup

1. Clone the repository in WSL:
```bash
cd ~
mkdir legend-project
cd legend-project
git clone https://github.com/databricks-industry-solutions/legend-getting-started.git
cd legend-getting-started/docker
```

2. Create config.properties:
```properties
GITLAB_OAUTH_CLIENT=<your-client-id>
GITLAB_OAUTH_SECRET=<your-secret>
GITLAB_PROJECT_ID=<your-project-id>
GITLAB_DEPLOY_TOKEN_USERNAME=<deploy-token-username>
GITLAB_DEPLOY_TOKEN_PASSWORD=<deploy-token-password>
MONGO_PASSWORD=<choose-a-password>
HOST_DNS_NAME=localhost
```

3. Ensure proper line endings:
```bash
dos2unix config.properties
```

### 4. Docker Setup

1. Enable WSL integration in Docker Desktop:
   - Open Docker Desktop
   - Settings > Resources > WSL Integration
   - Enable Ubuntu
   - Apply & Restart

2. Add user to docker group in WSL:
```bash
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
```

## Running Legend

1. Configure the environment:
```bash
./legend.sh configure
```

2. Start the services:
```bash
./legend.sh start
```

3. Access Legend Studio at: `http://localhost:8080/studio`

## Legend Model Development

1. Create a project in Legend Studio:
   - Group ID: `com.databricks.legend.demo`
   - This will create a GitLab repository with Maven project structure

2. Load the model:
   - Use Pure Grammar to load model definitions from example.pure file
   - Model includes: enums, classes, services, mappings
   - Commit changes to GitLab

## Build Legend Model JAR

1. Install Prerequisites:
   - JDK (from https://adoptium.net/)
   - Maven (from https://maven.apache.org/download.cgi)

2. Clone your Legend GitLab repository locally

3. Build the project:
```cmd
set MAVEN_OPTS=-Xmx1024m
mvn clean install
```
   - The main JAR will be in `employee-model-entities/target/`

## Databricks Setup

1. Create Databricks Cluster:
   - Runtime: 10.4 LTS (required for legend-delta compatibility)
   - Node Type: Standard_DS3_v2
   - Single Node cluster

2. Install Required Libraries:
   - Maven Central: `org.finos.legend-community:legend-delta:0.1.10`
   - PyPI: `PyYAML==6.0.2`
   - PyPI: `legend-delta==0.1.10`
   - Upload JAR: `employee-model-entities-0.0.1-SNAPSHOT.jar`

3. Configure Legend Studio Connection:
   - Go to Compute -> Your cluster -> Configuration -> Advanced options
   - Note down these values:
     - Hostname: Found in Server Hostname (e.g., `adb-<workspace-id>.<random-number>.azuredatabricks.net`)
     - HTTP Path: Found in JDBC/ODBC tab, use the Cluster HTTP Path format: `sql/protocolv1/o/<workspace-id>/<cluster-id>`
   - Create a Personal Access Token in Azure Databricks (User Settings -> Developer -> Access tokens)
   - Update `vault.properties` with your token:
     ```properties
     com.databricks.cloud.azure = dapi<your-token>
     ```

4. Configure Connection in Legend Studio:
   - Open your model
   - Find the connection definition (e.g., `databricks::lakehouse::employee`)
   - Update the connection details:
     - Hostname: Use the Server Hostname from step 3
     - Protocol: `https`
     - Port: `443`
     - HttpPath: Use the Cluster HTTP Path from step 3
     - AccessTokenRef: `com.databricks.cloud.azure`

5. Upload Sample Data:
   - In the Databricks UI, click on New -> Add or upload data -> Upload files to DBFS
   - Upload the `notebooks/data/MOCK_DATA.json` file

6. Import and Run Notebook:
   - Import `01_legend_delta.py`
   - Attach to cluster
   - Run all cells