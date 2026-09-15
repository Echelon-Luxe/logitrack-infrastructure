{{- define "logitrack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "logitrack.labels" -}}
app.kubernetes.io/part-of: logitrack
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Deployment spec.selector is immutable - never put chart version or image tag here. */}}
{{- define "logitrack.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{/* deepCopy is required: without it mergeOverwrite mutates .Values.defaults,
     leaking the first service's overrides into every later service. */}}
{{- define "logitrack.config" -}}
{{- $merged := mergeOverwrite (deepCopy .root.Values.defaults) (deepCopy .svc) -}}
{{- toYaml $merged -}}
{{- end -}}
