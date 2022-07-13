FROM node:lts-alpine3.12

WORKDIR /app
RUN apk add --no-cache --virtual .build-deps git \
    && npm init --yes \
    && npm install zenn-cli \
    && apk del .build-deps
COPY articles articles
COPY images images
COPY books books

EXPOSE 8000
ENV PORT 8000

ENTRYPOINT ["npx","zenn" , "preview"]