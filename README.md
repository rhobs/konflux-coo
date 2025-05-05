# Konflux Cluster Observability Operator

## Catalog resources:
Catalog was generated via
```
opm alpha render-template basic --output yaml --migrate-level bundle-object-to-csv-metadata catalog/catalog-template.yaml > catalog/coo-product/catalog.yaml
opm alpha render-template basic --output yaml --migrate-level catalog/catalog-template.yaml > catalog/coo-product-4.16/catalog.yaml
```

or simply use `make generate`

## Random notes on release automation

* Rebuild a component by adding build.appstudio.openshift.io/request: 
  trigger-pac-build  annotation to component

### Release when builds are randomly failing
Start from the release side. The operator is auto-released. The EC tests will 
tell you about any issues.
Failing on-push builds show up as
```
[Violation] olm.unmapped_references
  ImageRef: quay.io/redhat-user-workloads/cluster-observabilit-tenant/cluster-observability-operator/cluster-observability-operator-bundle@sha256:a1c673984717fdb0e820e59c6c7f216915b6fbfe07bcfff322275a89a28d0347
  Reason: The
  "registry.redhat.io/cluster-observability-operator/monitoring-console-plugin-0-4-rhel9@sha256:24f0f54749d890397bdfa7cc840cae85039645dc9021f8ecc67d8a1ada42fcf9"
  CSV image reference is not in the snapshot or accessible.
  Title: Unmapped images in OLM bundle
```

Rerun the build by
`kubectl annotate component monitoring-console-plugin-0-4-1-1 build.appstudio.openshift.io/request=trigger-pac-build`

Do this until all builds are in the snapshot.
