---
title: "Googleアナリティクス4が出たので、アクセス履歴を元にBigQueryでデータ分析してみた"
emoji: "🐝"
type: "tech" 
topics: ["BigQuery","GoogleAnalytics","ga4"]
published: true
---

## TL;DR
- Googleアナリティクス4から有料版の360を利用せずに、アクセスログをBigQueryに転送できるようになった
- Googleアナリティクス4のデータを元にBigQueryデータ分析をしてみた
- 経路別のユーザ登録数を出してみる

## Google アナリティクス4とは
2019年に発表された「アプリ＋ウェブ プロパティ」が、2020年10月から正式にリリースされた新しいプロパティです。
https://support.google.com/analytics/answer/10089681
以下GA4とする

### 特徴
- ページビューや発火イベントなどを全て「イベント」として、管理される
- Webだけでなく、アプリも計測可能
- 無料版のGAでもBigQueryへのデータエクスポートが可能に
- 旧アナリティクス にはできて、GA4ではできないこともある(search console設定など)

## 実際にBigQueryでGA4のデータを分析してみる
今回はBigQueryへのデータエクスポートをしてアクセスログをBigQueryでデータ分析をしてみます

### 分析内容
以下の想定で分析してみます
#### ユーザ登録フロー
![](https://storage.googleapis.com/zenn-user-upload/j9e1lu9eef56egi7zfm0piwzig6l)

1. LPに遷移
    - 経路別をGAで判定するために、`utm_xx`をクエリパラメータに追加されている

2. 登録ページに遷移するボタンからサービス登録ページに遷移
    - 違うドメイン or クエリパラメータを引き継げないなどのため、クリックボタンを押した時にGAのイベントを発火させる

3. 登録
    - 登録時にデータベースに登録ユーザと`utm_campaign`を紐付ける

### 想定のテーブル設計
下記テーブルのデータがBigQueryにも連携されているとします

```sql
-- ユーザ情報が格納されているテーブル
CREATE TABLE `user` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `name` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ユーザ登録時のutm_campainを取得
CREATE TABLE `user_referrer` (
  `user_id` bigint NOT NULL,
  `utm_campaign` varchar(255) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`user_id`)
)ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```


余談ですが、`cloud_sql`を利用している場合、`CloudSQL Federation`を利用するとUIで連携できるのでかなりお勧めです
https://qiita.com/fuku_tech/items/1c0a1d1d1e59cd188e2f


## 手順
大きな流れは
1. GA4をLPに設置
2. GA4からBigQueryへのデータエキスポート設定
3. BigQueryでクエリ実行

### GA4導入
https://support.google.com/tagmanager/answer/9442095?hl=ja

わかりやすい記事があったので、こちらを参照すると良いと思います。
https://blog.apar.jp/web/14911/

### GA4->BigQueryの連携
わかりやすい記事があったので、こちらを参照すると良いと思います。
この記事にも書かれているのですが、ストリーミングでのデータエキスポートは費用が高いので、毎日のバッチでのエキスポートを前提としてクエリを書いてみます
https://yoshihiko-nakata.com/archives/799

### BigQueryでGA4のページビューを見てみる
BigQueryでは、GA4のデータが`analytics_xxxxxx`/`event_YYYYMMDD` で日毎にデータが格納されています

```sql
SELECT DATE(DATETIME_ADD(PARSE_DATETIME("%Y%m%d", event_date), INTERVAL 9 HOUR)) AS event_date,
        event_timestamp,
        event_name,
        traffic_source.name AS campaign,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'link_domain') AS link_domain
FROM `xxxxxxx.analytics_YYYYMMDD.events_*`
WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE("%Y%m%d", PARSE_DATE("%Y-%m-%d", '2021-01-05')) AND FORMAT_DATE("%Y%m%d", PARSE_DATE("%Y-%m-%d", '2021-01-17')
AND  event_name = 'page_view';
```

- GA4のデータは階層になっているので、平坦化する必要があります。
GA4のスキーマ
https://support.google.com/analytics/answer/7029846?hl=en&ref_topic=9359001
- `traffic_source.name`にcampaignのデータが入ってます
- `_TABLE_SUFFIX`で、わざわざ`PARSE_DATE`しているのはRedashで日付を変数とする時に変更しやすくするために置いてます
- `event_name`は`page_view`にします。またクリックイベントは`click`になるので、適宜修正します。
- `link_domain`はクリックイベント時の際に遷移する先のdomainです。

### ユーザの登録経路を取得する
```sql
SELECT 
    user_id, 
    utm_campaign,
    DATE(DATETIME_ADD(created_at, INTERVAL 9 HOUR)) AS registered_date,
FROM xxxxx.user_referrer
```

### 経路別の登録数を取得する
上記2つのクエリを合わせて取得します。
日付と経路別に登録ページクリック数/登録ユーザ数を出します。

```sql
WITH 
analytics AS
  (SELECT DATE(DATETIME_ADD(PARSE_DATETIME("%Y%m%d", event_date), INTERVAL 9 HOUR)) AS event_date,
        event_timestamp,
        event_name,
        traffic_source.name AS campaign,
        (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'link_domain') AS link_domain -- clickイベント時の遷移先ドメイン
    FROM `xxxxxxx.analytics_YYYYMMDD.events_*`
    WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE("%Y%m%d", PARSE_DATE("%Y-%m-%d", '2021-01-05')) AND FORMAT_DATE("%Y%m%d", PARSE_DATE("%Y-%m-%d", '2021-01-17')
    AND  (event_name = 'page_view' OR event_name = 'click')),
user_ref AS
  (SELECT user_id, utm_campaign
    FROM xxxxx.user_referrer),
analytics_sum AS
  (SELECT event_date,
          utm_campaign,
          COUNTIF(event_name = "page_view") AS page_view,
          COUNTIF(event_name = "click" AND link_domain = "register.xxxx.com") AS click_register_button -- 登録ページに遷移するボタンのみカウント
   FROM analytics
   GROUP BY event_date, utm_campaign)

SELECT  analytics_sum.event_date, -- アクセスログの日
        analytics_sum.utm_campaign AS utm_campaign, -- utm_campaign
        analytics_sum.page_view AS page_view, -- ページビュー
        analytics_sum.click_register_button AS click_register_button_count, --登録ページ遷移ボタンクリック
        count(user_ref.user_id) AS sum, -- 登録数
FROM analytics_sum
LEFT JOIN user_ref ON user_ref.registered_date = analytics_sum.event_date AND user_ref.utm_campaign = analytics_sum.utm_campaign
GROUP BY analytics_sum.event_date,
         analytics_sum.page_view,
         analytics_sum.click_register_button,
         analytics_sum.utm_campaign
ORDER BY analytics_sum.event_date DESC, analytics_sum.utm_campaign DESC

```

1. `analytics`では、`page_view`・`click`イベントを取得
2. `user_ref`ではユーザの登録経路一覧
3. `analytics_sum`は日付毎のクリック数とページビュー数をカウント(もし他のURIのページビューが含まれている場合は、フィルタリングする)
4. `user_ref`と`analytics_sum`を合わせて出す


## 感想
個人ではサービスのデータ内でのデータ分析しかできなかったのが、流入までまとめて分析できるので、ビジネス施策を考える時の幅が広がるのではないでしょうか。
また、webだけでなくアプリでも利用できるので、次試してみたいと思います。
