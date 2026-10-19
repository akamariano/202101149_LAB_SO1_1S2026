{{/* Nombre base: el operador usa el nombre del CR como nombre del release. */}}
{{- define "grafana.name" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "grafana.labels" -}}
app.kubernetes.io/name: grafana
app.kubernetes.io/instance: {{ include "grafana.name" . }}
app.kubernetes.io/managed-by: mumnk8s-operator
{{- end -}}

{{- define "grafana.selector" -}}
app.kubernetes.io/name: grafana
app.kubernetes.io/instance: {{ include "grafana.name" . }}
{{- end -}}
