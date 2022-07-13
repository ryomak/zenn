gcloud config set project "$GCLOUD_PROJECT"
gcloud auth configure-docker

build_name="gcr.io/$GCLOUD_PROJECT/zenn-preview"
docker build --platform linux/amd64 -t $build_name .
docker push $build_name

service_name="zenn-preview-$(uuidgen | tr [:upper:] [:lower:])"
gcloud run deploy $service_name \
  --image $build_name \
  --port 8000 \
  --allow-unauthenticated \
  --region asia-northeast1