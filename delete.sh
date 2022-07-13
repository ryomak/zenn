# service_name = zenn-preview-xxxxxx
service_name=
gcloud run services delete "$service_name" --platform managed --region asia-northeast1
gcloud container images delete "gcr.io/$GCLOUD_PROJECT/zenn-preview"