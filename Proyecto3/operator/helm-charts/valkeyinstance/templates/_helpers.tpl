{{/* Nombre base: el operador usa el nombre del CR como nombre del release. */}}
{{- define "valkey.name" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "valkey.labels" -}}
app.kubernetes.io/name: valkey
app.kubernetes.io/instance: {{ include "valkey.name" . }}
app.kubernetes.io/managed-by: mumnk8s-operator
{{- end -}}

{{- define "valkey.selector" -}}
app.kubernetes.io/name: valkey
app.kubernetes.io/instance: {{ include "valkey.name" . }}
{{- end -}}
