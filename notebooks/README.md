# Legend Databricks Integration Notebook

The main notebook (`01_legend_delta.py`) demonstrates how Legend data models work with Databricks.

## How It Works

The notebook shows a simple end-to-end workflow:

1. **Load the Legend model**
   ```python
   legend = LegendClasspathLoader().loadResources()
   ```
   The notebook loads a pre-compiled Legend model from a JAR file in the classpath.

2. **Extract schema information**
   ```python
   schema = legend.get_schema("databricks::entity::employee")
   ```
   Gets the Spark schema representation of a Legend entity, including field names, data types, and descriptions.

3. **Get transformations**
   ```python
   transformations = legend.get_transformations("databricks::mapping::employee_delta")
   ```
   Retrieves mappings that show how to transform source field names to target field names.

4. **Get validation rules**
   ```python
   expectations = legend.get_expectations("databricks::mapping::employee_delta")
   ```
   Gets business and technical data quality rules defined in the Legend model.

5. **Get derived fields**
   ```python
   derivations = legend.get_derivations("databricks::mapping::employee_delta")
   ```
   Gets calculated field expressions for fields that aren't stored but computed.

6. **Create Delta table**
   ```python
   legend.create_table("databricks::mapping::employee_delta")
   ```
   Creates a Delta table with the schema, constraints, and properties defined in Legend.

7. **Read and transform data**
   ```python
   schema_df = spark.read.format("json").schema(schema).load(data_path)
   for from_column in transformations.keys():
     schema_df = schema_df.withColumnRenamed(from_column, transformations[from_column])
   ```
   Reads JSON data using the Legend schema and applies field transformations.

8. **Write to Delta**
   ```python
   schema_df.write.format("delta").mode("append").saveAsTable(dst_table)
   ```
   Writes the transformed data to the Delta table, enforcing constraints.

9. **Query using Legend services**
   ```python
   df = legend.query('databricks::service::skills')
   ```
   Executes a Legend service definition as a Spark SQL query, including any grouping, filtering, or calculations.