# Legend Pure Model

This directory contains the Pure model definition used in the Legend Getting Started accelerator. The `example.pure` file defines a data model for employee data management.

## Overview

The Legend Pure model in `example.pure` is organized into several sections:

1. **Services** - REST API endpoints for querying data
2. **Relational Schema** - Database table definitions
3. **Pure Classes** - Logical data model definitions
4. **Mapping** - Connections between logical and physical models
5. **Connection** - Database connection configuration
6. **Runtime** - Execution environment configuration

## Model Development in Legend Studio

Before using this model in Databricks, you'll need to:

1. Set up a local Legend environment (see `docker/README.md`)
2. Create a project in Legend Studio with Group ID format: `com.databricks.legend.*`
3. Import the Pure grammar from the `example.pure` file
4. Commit changes to your GitLab repository

This process creates a Maven project structure in GitLab that can be built locally.

## Model Components

### Services

The model defines two services:
- `databricks::service::skills` - Provides diversity metrics grouped by gender with average high-fives
- `databricks::service::employee` - Retrieves employee data filtered by first name starting with 'G'

Each service defines:
- API endpoint pattern
- Owners
- Documentation
- Query expression in Pure
- Mapping and runtime configurations

### Relational Schema

The model defines a database schema for employee data:
```
Database databricks::table::schema
(
  Schema legend
  (
    Table employee
    (
      id INTEGER PRIMARY KEY,
      first_name VARCHAR(255),
      last_name VARCHAR(255),
      birth_date DATE,
      gender VARCHAR(255),
      sme VARCHAR(255),
      joined_date DATE,
      high_fives INTEGER
    )
  )
)
```

### Pure Classes

The model defines several Pure classes:

1. **SME Enumeration** - Programming skills enumeration (Scala, Python, Java, R, SQL)

2. **Employee Class** - Extends the Person class with:
   - Properties:
     - `id`: Unique employee identifier
     - `sme`: Programming skill mastery
     - `joinedDate`: Employment start date
     - `highFives`: Recognition count
   - Derived properties (calculated fields):
     - `hiringAge()`: Age at hiring
     - `age()`: Current age
     - `initials()`: Employee initials

3. **Person Class** - Base class with:
   - Properties:
     - `firstName`: Person's first name
     - `lastName`: Person's last name
     - `birthDate`: Date of birth
     - `gender`: Person's gender
   - Derived properties:
     - `age()`: Calculated age
     - `initials()`: Person's initials

4. **Helper Function**:
   - `compute_age()`: Calculates age based on birth date

### Mapping

The `databricks::mapping::employee_delta` mapping connects the logical model to the physical database:
- Maps class properties to database columns
- Defines primary keys
- Maps enumeration values

### Connection

Database connection configuration for Databricks:
```
RelationalDatabaseConnection databricks::lakehouse::employee
{
  store: databricks::table::schema;
  type: Databricks;
  specification: Databricks
  {
    hostname: 'XXXXXXXXXXXXXX';
    port: '443';
    protocol: 'https';
    httpPath: 'XXXXXXXXXXXXXX';
  };
  auth: ApiToken
  {
    apiToken: 'XXXXXXXXXXXXXX';
  };
}
```

**Important:** The connection configuration properties (hostname, httpPath, apiToken) must be taken from your specific Databricks environment:
- `hostname`: The server hostname from your Databricks workspace (e.g., `adb-<workspace-id>.<random-number>.azuredatabricks.net`)
- `httpPath`: The cluster HTTP path from JDBC/ODBC connection details (format: `sql/protocolv1/o/<workspace-id>/<cluster-id>`)
- `apiToken`: A Databricks personal access token created in the User Settings → Developer → Access tokens section of the Databricks workspace, typically stored in `vault.properties` with a reference like `com.databricks.cloud.azure`

### Runtime

The runtime configuration combines mappings and connections for execution:
```
Runtime databricks::runtime::employee
{
  mappings:
  [
    databricks::mapping::employee_delta
  ];
  connections:
  [
    databricks::table::schema:
    [
      environment: databricks::lakehouse::employee
    ]
  ];
}
```