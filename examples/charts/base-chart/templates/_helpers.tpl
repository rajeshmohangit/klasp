{{/*
Expand the name of the chart.
*/}}
{{- define "base-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "base-chart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "base-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels following Kubernetes recommended labels
*/}}
{{- define "base-chart.labels" -}}
helm.sh/chart: {{ include "base-chart.chart" . }}
{{ include "base-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "base-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "base-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
This is now a simple helper that defaults to "default"
Service accounts should be defined in the serviceAccounts array
*/}}
{{- define "base-chart.serviceAccountName" -}}
default
{{- end }}

{{/*
Common annotations
*/}}
{{- define "base-chart.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Render a container spec with granular field support
Usage: include "base-chart.container" $containerConfig
*/}}
{{- define "base-chart.container" -}}
- name: {{ required "Container name is required" .name }}
  {{- if typeIs "string" .image }}
  image: {{ required "Container image is required" .image }}
  {{- else if .image }}
  image: "{{ required "Container image.repository is required" .image.repository }}{{ if .image.tag }}:{{ .image.tag }}{{ end }}"
  {{- else }}
  {{- required "Container image is required" .image }}
  {{- end }}
  {{- with .imagePullPolicy }}
  imagePullPolicy: {{ . }}
  {{- end }}
  {{- with .command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .env }}
  env:
    {{- range . }}
    - name: {{ .name }}
      {{- if .value }}
      value: {{ .value | quote }}
      {{- else if .valueFrom }}
      valueFrom:
        {{- toYaml .valueFrom | nindent 8 }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- with .envFrom }}
  envFrom:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .ports }}
  ports:
    {{- range . }}
    - name: {{ .name }}
      containerPort: {{ .containerPort }}
      protocol: {{ .protocol | default "TCP" }}
      {{- with .hostPort }}
      hostPort: {{ . }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- with .livenessProbe }}
  livenessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .readinessProbe }}
  readinessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .startupProbe }}
  startupProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .resizePolicy }}
  resizePolicy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .volumeMounts }}
  volumeMounts:
    {{- range . }}
    - name: {{ .name }}
      mountPath: {{ .mountPath }}
      {{- with .subPath }}
      subPath: {{ . }}
      {{- end }}
      {{- with .readOnly }}
      readOnly: {{ . }}
      {{- end }}
      {{- with .mountPropagation }}
      mountPropagation: {{ . }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- with .volumeDevices }}
  volumeDevices:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .lifecycle }}
  lifecycle:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .workingDir }}
  workingDir: {{ . }}
  {{- end }}
{{- end }}
