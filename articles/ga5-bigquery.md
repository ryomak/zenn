---
title: "Googleアナリティクス4のデータをBigQueryに入れて分析する"
emoji: "🐝"
type: "tech" 
topics: ["BigQuery","GoogleAnalytics","ga4"]
published: true
---

## TL;DR
- Googleアナリティクス4から有料版の360を利用せずに、アクセスログをBigQueryに転送できるようになりました
- Googleアナリティクス4のデータを元にBigQueryデータ分析をする時の手順をまとめました
- ケース別のクエリとTipsをまとめました

## はじめに
こんにちは、[Unlace](https://www.unlace.net/)を運営している株式会社Unlaceのryomakです。
今回新たにGoogle アナリティクス4が利用できるようになったので、BigQueryにデータを入れて分析してみました。

## Google アナリティクス4とは
2019年に発表された「アプリ＋ウェブ プロパティ」が、2020年10月から正式にリリースされた新しいプロパティです。
https://support.google.com/analytics/answer/10089681
以下GA4とします

### 特徴
- ページビューや発火イベントなどを全て「イベント」として、管理される
- Webだけでなく、アプリも計測可能
- 無料版のGAでもBigQueryへのデータエクスポートが可能に
- 旧アナリティクス にはできて、GA4ではできないこともある(search console設定など)

## 実際にBigQueryでGA4のデータを分析する
今回はBigQueryへのデータエクスポートをしてアクセスログをBigQueryでデータ分析をしてみます

### BQへのデータ連携手順
1. GA4をデータ収集したいサイトに追加
2. **GA4からBigQueryへのデータエクスポートの設定**
3. BigQueryでクエリ実行

### GA4をデータ収集したいサイトに追加
TagManagerでの設置が、プロダクトコードにかかわらず変更できるので、おすすめです。
https://support.google.com/tagmanager/answer/9442095?hl=ja

### GA4からBigQueryへのデータエクスポートの設定
わかりやすい記事があったので、こちらを参照すると良いと思います。
こちらの記事にも書かれているのですが、ストリーミングでのデータエクスポートは費用が高いので、
毎日のバッチでのエクスポートを前提としてクエリを書いてみます

https://yoshihiko-nakata.com/archives/799

## ケース別BigQueryのクエリ
BigQueryでは、GA4のデータが`analytics_xxxxxx_events_YYYYMMDD` テーブルに日毎にデータが格納されています。
このデータはローデータなので、PageViewの他にカスタムイベントやクリックイベントなど、全てのデータが連携されます。
細かいカラムについては、以下のデータスキーマ表をご確認ください。

[データスキーマ](https://support.google.com/firebase/answer/7029846?hl=ja)

### pageview
```sql
SELECT 
        event_timestamp,
        event_name,
        traffic_source.name AS campaign,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_referrer') AS page_referrer,
        device.category AS device, 
        device.web_info.browser AS device_browser,
FROM `xxxxxxx.analytics_YYYYMMDD.events_20220101`
WHERE event_name = 'page_view';
```

#### 説明
- GA4のデータは階層になっているので、event_paramsを平坦化して、location等を取得します
- `traffic_source.name`にcampaignのデータが入ってます
- `event_name`は`page_view`にします。またクリックイベントは`click`になるので、適宜修正します。

#### カスタムイベント
```sql
SELECT 
          event_timestamp,
          event_name,
          (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location,
          (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'customParam1') AS custom_one,
          (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'customParam2') AS custom_two,
          (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'customParam3') AS custom_three,
          (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'customParam4') AS custom_four,
FROM `xxxxxxx.analytics_YYYYMMDD.events_20220101`
WHERE event_name = 'customEvent'
```
#### 説明
- `event_name` にはカスタムイベントの名前が入ります
- `event_params`にカスタムデータが入っているので、取り出しています


## Tips
GAの分析に際して、BigQueryで利用しているものをご紹介します。
### スケジュールクエリ
BQにはクエリを定期的に実行して、データを入れてくれる仕組みがあります。
GA4のデータは日別でデータに入るため、そのデータを丸ごと、加工して分析テーブルに突っ込んでいます。
※ GA4のBQ連携はたまに、遅延する時があるので、前日のデータが入らない時があるので注意です。

### UDFの利用
UDF=user-defined functionsを利用することで、クエリを共通化できます。
`page_location` と`page_referrer`カラムにはURLがそのまま入っているので、こちら分解するのに利用しています。

```sql
-- URLからドメインを取り出すUDF
CREATE OR REPLACE FUNCTION `udf.PARSE_URL_DOMAIN`(url STRING) RETURNS STRING AS (
   regexp_extract(url, '//([^/]+)')
);

-- URLからパスを取り出すUDF
CREATE OR REPLACE FUNCTION `udf.PARSE_URL_PATH`(url STRING) RETURNS STRING AS (
   regexp_extract(url, '//[^/]+([^?#]+)')
);

-- URLからプロトコルを取り出すUDF
CREATE OR REPLACE FUNCTION `udf.PARSE_URL_PROTOCOL`(url STRING) RETURNS STRING AS (
   regexp_extract(url, '^([^:]+)')
);

```

### 1ユーザあたりの流れを知りたい時
`user_pseudo_id`というカラムにユーザの仮のIDが付与されているので、このカラムを引き回して、ユーザの流れを分析します

## 感想
UIだけで連携できるので、本当に便利すぎですね。
GA4からアプリとウェブが横断的に計測できるようになったので、Googleには感謝しかないですね。