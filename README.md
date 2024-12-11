# Konflux Cluster Observability Operator

## Catalog resources:
Catalog was generated via
```
opm alpha render-template basic --output yaml  catalog/catalog-template.yaml > catalog/coo-product/catalog.yaml
opm alpha render-template basic --output yaml --migrate-level bundle-object-to-csv-metadata catalog/catalog-template-4.17.yaml > catalog/coo-product-4.17/catalog.yaml
```
