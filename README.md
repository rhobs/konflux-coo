# Konflux Cluster Observability Operator

## Catalog resources:
Catalog was generated via
```
opm alpha render-template basic --output yaml --migrate-level bundle-object-to-csv-metadata catalog/catalog-template.yaml > catalog/coo-product/catalog.yaml
opm alpha render-template basic --output yaml --migrate-level catalog/catalog-template.yaml > catalog/coo-product-4.16/catalog.yaml
```

or simply use `make generate` 
