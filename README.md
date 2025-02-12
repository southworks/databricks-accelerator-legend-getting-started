# Legend Getting Started

<img src=https://d1r5llqwmkrl74.cloudfront.net/notebooks/fsi/fs-lakehouse-logo-transparent.png width="600px">

[![DBR](https://img.shields.io/badge/DBR-10.4-red?logo=databricks&style=for-the-badge)](https://docs.databricks.com/release-notes/runtime/10.4.html)
[![CLOUD](https://img.shields.io/badge/CLOUD-ALL-blue?logo=googlecloud&style=for-the-badge)](https://cloud.google.com/databricks)
[![POC](https://img.shields.io/badge/POC-10_days-green?style=for-the-badge)](https://databricks.com/try-databricks)

*In addition to the JDBC connectivity enabled to Databricks from the legend-engine itself, this project helps
organizations define data models that can be converted into efficient data pipelines, ensuring data being queried
is of high quality and availability. Raw data can be ingested as stream or batch and processed in line with the
business semantics defined from the Legend interface. Domain specific language defined in Legend Studio can be
interpreted as a series of Spark SQL operations, helping analysts create Delta Lake tables that not only guarantees
schema definition but also complies with expectations, derivations and constraints defined by business analysts.*

___

<antoine.amend@databricks.com>

___

<img src='https://raw.githubusercontent.com/databricks-industry-solutions/legend-getting-started/main/images/reference_architecture.png' width=800>

___

## Deploy to Azure

You can deploy the accelerator to Azure using the button below:

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsouthworks%2Fdatabricks-accelerator-legend-getting-started%2Faccelerator-updates%2Fdeploy-azure%2Fmain.json)

## Manual Setup

For a manual setup of a local instance of Legend, as well as a manual setup of an Azure Databricks resource, see [these instructions](docker/README.md).

___

&copy; 2022 Databricks, Inc. All rights reserved. The source in this notebook is provided subject to the Databricks License [https://databricks.com/db-license-source].  All included or referenced third party libraries are subject to the licenses set forth below.

| library                                | description        | license | source                                 |
|----------------------------------------|--------------------|---------|----------------------------------------|
| PyYAML                                 | Reading Yaml files | MIT     | https://github.com/yaml/pyyaml         |
| legend-delta                           | Legend delta       | Apache2 | https://pypi.org/project/legend-delta/ |
