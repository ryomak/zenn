---
title: "GCPでSendGridのメール内リンクをSSL化する"
emoji: "📧"
type: "tech"
topics: ["SendGrid","GCP"]
published: true
---

SendGridのClickTracking機能により、メール内のリンククリックイベントを追跡することができます

デフォルトだと、メール内のリンクはすべて`sendgrid.net`ドメインのリンクに書き変わり、送信ドメインとリンクのドメインが異なるため、メールの信頼性を損なう可能性があります。
独自ドメインを使用することで、この問題を解決し、メールの到達率を高めることが可能になります。
[Link Branding](https://sendgrid.kke.co.jp/docs/User_Manual_JP/Settings/Sender_authentication/How_to_set_up_link_branding.html)という仕組みで、独自ドメインを利用することができます。

Link Brandingの設定をすると、メール内のリンクは設定した独自ドメインに変換されますが、初期の設定では、`http://`で始まるリンクになってしまいます。

https://news.mynavi.jp/techplus/article/20231031-2807397/

Chromeなどのブラウザのアップデートで、HTTP接続が自動でHTTPS接続にリダイレクトされるようになり、メール内のリンクが`http://`だと、ブラウザで開くと正常に表示できなくなってしまう場合があります。
この問題を解決するために、メール内リンクをSSL化する必要があります。

今回は、GCPのみでメールのSSL化対応する方法をまとめます。

## 前提
以下を利用します
- Cloud Load Balancing
- Cloud DNS

## 手順の方針

他のCDNと違って、GCPのCloudCDNだと、SSL証明書ありでのSendGridへのプロキシができないため、以下サイトの`Using a Proxy`の方法で設定します。
https://support.sendgrid.com/hc/en-us/articles/4447646844187-Enabling-SSL-for-Click-and-Open-Tracking-for-Your-Account

```go
手順1. Domain AuthenticationとLink Brandingを設定する

手順2. HTTPS接続によるリクエストを受け取り、sendgrid.netからの正確な応答を返すプロキシを構築する。

手順3. Link Brandingで登録したドメインのアクセス先を構築したプロキシに変更する

手順4. SendGridのサポートにSSL Click Trackingを有効化してもらう
```

### 今回の手順で利用するドメインは以下と仮置きします。
- Link Brandingでのドメインは、`url.example.com`とします
- sendgridをproxyするドメインは、`proxy.example.com`とします

### 構成
```mermaid
sequenceDiagram
    participant User as ユーザー
    participant UrlDomain as url.example.com
    participant Proxy as proxy.example.com
    participant SendGrid as sendgrid.net

    User->>UrlDomain: リンククリック
    UrlDomain->>Proxy: CNAME (リダイレクト)
    Proxy->>SendGrid: プロキシ経由でリクエスト
    SendGrid->>Proxy: レスポンス
    Proxy->>User: レスポンス

```


## 手順1 Domain AuthenticationとLink Brandingを設定する
SendGrid管理画面->Settings->Sender Authentication->Link Brandingで設定できます。
urlを設定した後は、管理画面に沿って、CNAMEレコードを設定しstatusが`verified`になるのを確認します。
```
# 例
url.example.com. 300 IN CNAME sendgrid.net.
```


## 手順2 HTTPS接続によるリクエストを受け取り、sendgrid.net からの正確な応答を返すプロキシを構築する。
まずはCloud Load Balancingの設定をします。
HTTPS接続で、proxy.example.comにアクセスすると、sendgrid.netから応答が返るようになるのがゴールです。

### SendGridにプロキシするためのパスルールを設定
1. `sendgrid.net`に443ポートでプロキシするためのネットワーク エンドポイント グループを作成
   - 種類: インターネットNEG
   - 範囲: Global
   - ポート: 443
   - 追加手段: 完全修飾ドメインとポート
   - ドメイン: `sendgrid.net`
2. 作成したエンドグループををもとに、バックエンドサービスを作成
   - バックエンドタイプ: インターネットネットワークエンドグループ
   - ネットワークエンドポイントグループ: 1で作成したネットワークエンドポイントグループ
   - プロトコル: HTTPS
3. バックエンドサービスをもとに、URLマップを作成
   - パスのルール: 全て
   - ドメイン： `proxy.example.com`
   - バックエンドサービス: 2で作成したバックエンドサービス



### url.example.comとproxy.example.comのSSL証明書を作成し、Cloud Load Balancingに割り当てる
https://cloud.google.com/certificate-manager/docs/overview?hl=ja  
こちらを利用して、 `url.example.com`と`proxy.example.com`のSSL証明書を作成します。
そして、作成した証明書を、Cloud Load BalancingのURLマップに割り当てます。

Certification Managerを使わず、[直接証明書を発行する方法](https://cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs?hl=ja)もあります。  
しかし、設定した全てのドメインがロードバランサーに向いていないと、証明書の発行に失敗するため、あらかじめSSL証明書を作りたい場合は、Certification Managerを利用することをおすすめします。今回は、Certification Managerを利用します。


#### DNS認証を行う
```bash
## DNS認証を作成する
$ gcloud certificate-manager dns-authorizations create cert-sendgrid-url-domain --domain="url.example.com"
$ gcloud certificate-manager dns-authorizations create cert-sendgrid-proxy-domain --domain="proxy.example.com"

## describeにて、記載されているCNAMEレコードをCloud DNSに追加します。
## これで、DNS認証が完了です。
$ gcloud certificate-manager dns-authorizations describe cert-sendgrid-url-domain
$ gcloud certificate-manager dns-authorizations describe cert-sendgrid-proxy-domain
```

#### Google マネージド証明書を作成し、 証明書マップ/マップエントリを作成する
```bash
## Google マネージド証明書を作成します。
$ gcloud certificate-manager certificates create proxy-sendgrid-certificate -- domains="proxy.example.com,url.example.com" --dns-authorizations="cert-sendgrid-proxy-domain,cert-sendgrid-url-domain"

## 証明書マップを作成します。
$ gcloud certificate-manager maps create cert-proxy-map
## マップエントリを作成し、証明書マップに割り当てます。
$ gcloud certificate-manager maps entries create proxy-sendgrid-entry \
   --map="cert-proxy-map" \
   --certificates="proxy-sendgrid-certificate" \
   --hostname="proxy.example.com"
````

#### Cloud Load BalancingのURLマップに証明書マップを割り当てる
```bash
gcloud beta compute target-https-proxies update {loadbalancer名} --certificate-map="cert-proxy-map" --global
```


## Link Brandingで登録したドメインのアクセス先を構築したプロキシに変更する
CNAMEを利用して、`url.example.com`のアクセス先を`proxy.example.com`に変更します。
```
url.example.com. 300 IN CNAME proxy.example.com.
```

*注意点*
この対応にてレコード変更した後は、Link Brandingの再Verifyを行わないでください。
なぜなら、今回の対応で`url.example.com`のCNAMEが、`sendgrid.net`に向いていないため、Verifyに失敗してしまうからです。

## SendGridのサポートにSSL Click Trackingを有効化してもらう
https://support.sendgrid.com/hc/en-us/requests/new
こちらから問い合わせします
問題なければ、半日程度でサポートチームの方から、SSL Click Trackingが有効化された旨の返信がきます。


## 最後に
今回は、GCPのみを利用して、SendGridのメール内リンクをSSL化する方法をまとめました。
手順が多くハマりどころもあるので、参考になれば幸いです。


## 参考
以下の記事を参考にさせていただきました。
Cloudflareでの設定手順
https://zenn.dev/ken_yoshi/articles/5a45e0320352bc
Fastlyでの設定手順
https://zenn.dev/matken/articles/sendgrid-link-branding-fastly
CloudFrontでの設定手順
https://soudai.hatenablog.com/entry/2019/07/16/082105
