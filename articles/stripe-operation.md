---
title: "UnlaceでStripeを導入・運用してから1.5年経ったので振り返る"
emoji: "😚"
type: "tech"
topics: ["Stripe,"Go"]
published: false
---

## はじめに

こんにちは。[Unlace](https://www.unlace.net/?utm_campaign=unlace_f_tech_zenn)でエンジニアをしている、ryomakです！

### Unlaceについて
[Unlace](https://www.unlace.net/?utm_campaign=unlace_f_article_zenn)は、主にユーザ向けのテキストカウンセリングを含むメンタルヘルスケアのサービスを提供しています。  

(Unlaceがわかる画像)

加えて、登録カウンセラーの方が利用するUnlace for counselorや、企業が従業員に対してUnlaceの利用料金を負担する仕組みを提供する[Unlace for business](https://www.unlace.net/business?utm_campaign=unlace_f_tech_zenn)も提供しています。



Unlaceでは、上記サービスの決済基盤としてStripeを導入しました！

この記事では、決済基盤の技術選定と具体的な実装内容、そして、運用する中で得た気づきを、Unlaceでの活用事例として紹介します！

## 導入背景
Unlaceでは、APIサーバーにはGo、ユーザ・カウンセラー向けのWeb/AppをReact Nativeを採用しています。
フロント周りの構成に関しては、弊社フロントエンジニアが書いているこちらの記事をご覧ください。
[React & ReactNativeのmonorepo環境にViteを導入する](https://zenn.dev/yuto_iwashita/articles/vite-monorepo)

サービスをリリースした当初は、公式LINEアカウントを利用してカウンセラーとカウンセリングができるというサービスをβ版として提供をしていました。
決済については、LINE Payを用いて決済管理をしていましたが、自社のチャットシステムを載せ替えるにあたって、制限が多かったため、別の決済基盤に載せ替える必要がありました。

