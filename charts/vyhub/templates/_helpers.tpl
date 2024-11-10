{{/*
Return the common name for app componentes
*/}}
{{- define "vyhub.app.name" -}}
  {{- printf "%s-app" (include "common.names.fullname" .) | trunc 63 -}}
{{- end -}}

{{/*
Return the common name for geoipApi componentes
*/}}
{{- define "vyhub.geoipApi.name" -}}
  {{- printf "%s-geoip-api" (include "common.names.fullname" .) | trunc 63 -}}
{{- end -}}

{{/*
Return the common name for pdfApi componentes
*/}}
{{- define "vyhub.pdfApi.name" -}}
  {{- printf "%s-pdf-api" (include "common.names.fullname" .) | trunc 63 -}}
{{- end -}}

{{/*
Return the proper VyHub app image name
*/}}
{{- define "vyhub.app.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.app.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper VyHub frontend image name
*/}}
{{- define "vyhub.frontend.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.frontend.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper VyHub image name fror the GeoIP API
*/}}
{{- define "vyhub.geoipApi.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.geoipApi.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper VyHub image name for the PDF API
*/}}
{{- define "vyhub.pdfApi.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.pdfApi.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper image name for the init container volume-permissions image
*/}}
{{- define "vyhub.volumePermissions.image" -}}
{{- include "common.images.image" ( dict "imageRoot" .Values.volumePermissions.image "global" .Values.global ) -}}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "vyhub.imagePullSecrets" -}}
{{- include "common.images.renderPullSecrets" (dict "images" (list .Values.app.image .Values.volumePermissions.image) "context" $) -}}
{{- end -}}

{{/*
Create the name of the service account to use for the VyHub app.
*/}}
{{- define "vyhub.app.serviceAccountName" -}}
{{- if .Values.app.serviceAccount.create -}}
    {{ default (include "vyhub.app.name" .) .Values.app.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.app.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use for the VyHub GeoIP API.
*/}}
{{- define "vyhub.geoipApi.serviceAccountName" -}}
{{- if .Values.geoipApi.serviceAccount.create -}}
    {{ default (include "vyhub.geoipApi.name" .) .Values.geoipApi.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.geoipApi.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use for the VyHub PDF API.
*/}}
{{- define "vyhub.pdfApi.serviceAccountName" -}}
{{- if .Values.pdfApi.serviceAccount.create -}}
    {{ default (include "vyhub.pdfApi.name" .) .Values.pdfApi.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.pdfApi.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Return true if cert-manager required annotations for TLS signed certificates are set in the Ingress annotations
Ref: https://cert-manager.io/docs/usage/ingress/#supported-annotations
*/}}
{{- define "vyhub.ingress.certManagerRequest" -}}
{{ if or (hasKey . "cert-manager.io/cluster-issuer") (hasKey . "cert-manager.io/issuer") }}
    {{- true -}}
{{- end -}}
{{- end -}}
