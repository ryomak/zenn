---
title: "ドキュメントの校閲をサポートする仕組みをGASで作成する"
emoji: "📘"
type: "tech" 
topics: ["GAS","GoogleDrive"]
published: true
---


## 概要
Googleドライブに存在するドキュメントの文章を校閲する際のサポートツールを作成しました。

具体的には、
予め、校閲する際にチェックしたいワードをスプレッドシートで管理し、
GoogleDriveを監視し、ドキュメント内のチェックしたいワードに色をつけたり、リンクをつけたりするスクリプトを
GASで作成しました！


## 下準備
1. Google Driveに記事を入れておくフォルダを作ります。
2. 記事を入れておくフォルダに、チェックしたいワードを保持するスプレッドシートを作成します。

スプレッドシートには、以下画像のように、マッチさせたいキーワード、その際にマッチしているワードをマークするカラー、参考文献を一覧で記述します
![](https://storage.googleapis.com/zenn-user-upload/69154b5600d5369bf6eb621a.png)

3. スプレッドシートのURL内にスプレッドシートのIDがあるので、保存しておく
URLの{id}を保持しておきます。
```
https://docs.google.com/spreadsheets/d/{id}/edit#gid=xxx
```

4. ドキュメントを保存しているフォルダのIDを保持する
フォルダまで移動し、ブラウザに記載されているURLの{id}を保持しておきます
```
https://drive.google.com/drive/u/0/folders/{id}
```

### 下準備結果
ディレクトリ階層は以下のようなイメージです。
```go
review
|--checker.gsheet
|--example.gdoc
|--example1.gdoc
```

checkerというスプレッドシートにチェックするキーワードを入れつつ、校閲したいドキュメントを同じディレクトリに入れておきます。
今回はcheckerという名前にしましたが、ファイル名はなんでも良いです




## 実装
### スプレッドシートからチェックするワードを読みだす

matchers()を実行すると、スプレッドシートからマッチさせるキーワード一覧を取得できます

```js

class matcher {
    constructor(keyword,color, link){
      this.keyword = keyword;
      this.color = color;
      this.link = link;
    }
}

const matchers = () => {
    const app = SpreadsheetApp.openById("下準備3で保持しておいたスプレッドシートのID");
    const sheet = app.getSheetByName("スプレッドシートのシート名");
    const range = sheet.getRange(2, 1, sheet.getLastRow() - 1, 3);

    var list = [];
    for(var row = 1; row <= range.getNumRows(); row++) {
      const keyword = range.getCell(row, 1).getValue();
      const color = range.getCell(row, 2).getValue();
      const link = range.getCell(row, 3).getValue();
      list.push(new matcher(keyword, color, link));
    }

    return list;
}

```


### Google Driveにあるドキュメント一覧を取得する
getFilesById(フォルダのID)で、フォルダ内にある記事一覧を取得します

```js
const getFilesById = (id) => {
  //idを取得するフォルダの指定
  const folderId = DriveApp.getFolderById(id);
  //指定したフォルダ内のすべてのファイルを格納
  const files = folderId.getFiles();

  //データを格納する配列の宣言
  const arr = [];

  // 更新日が5分以内の記事だけ抽出
  let rangeTime =new Date();
  rangeTime.setMinutes(rangeTime.getMinutes() - 5);

  //2次元配列として追加
  //フォルダ内のすべてのファイルについて実行
  while (files.hasNext()) {
    //すべてのファイルから１つ取り出し
    const file = files.next();
    // google document以外無視
    if (file.getMimeType() != "application/vnd.google-apps.document") {
      continue;
    }
    // スルー
    if (file.getLastUpdated().getTime() < rangeTime.getTime()){
      continue;
    }
    //配列にファイルのデータを追加
    //getName：ファイルの名前、getId：ファイルのID、getUrl:ファイルのURL
    arr.push([file.getName(),file.getId(),file.getUrl()]);
  }
  return arr;
};

```

工夫した点として、
毎実行全てのファイルをチェックする必要はないので、ファイル最終更新が5分以内のファイルのみ取得しています

```js
if (file.getLastUpdated().getTime() < rangeTime.getTime()){
  continue;
}	
```

### 校閲のロジックを作る

ドキュメント内の文書を取り出して、マッチしたキーワードに、色を付けて・リンクをつけて・下線を追加
しました

```js
// ドキュメントのIDとマッチさせたいキーワードの一覧を引数として実行
const review = (id, matchers) => {
  let m = matchersToMap(matchers);
  var body = DocumentApp.openById(id).getBody();
  var asText = body.asText();
  var text = asText.getText();

  // マッチさせる正規表現
  var regexp = new RegExp(matchersToRegWord(matchers), 'g');
  var pos = 0;
  var posN = 0;

  // マッチした単語がなくなるまで
  while ((arr = regexp.exec(text)) !== null) {
    const matcher = m[arr];
    if (matcher == null) {
      continue
    }
    // 更新処理
    posN = body.asText().getText().indexOf(matcher.keyword, pos);
    if (posN !== -1) {
      const start = posN;
      const end = posN + arr[0].length  - 1 ;
      // 下線
      asText.setUnderline(start, end, true);
      // 背景に色を付ける
      asText.setBackgroundColor(start, end, matcher.color);
      // 補助リンク
      asText.setLinkUrl(start, end, matcher.link);
    }
    // 現在の位置を更新
    pos = regexp.lastIndex;
  }
}

// regexp
const matchersToRegWord = (matchers) => {
  let regWord = ""
  for (var i = 0; i < matchers.length; i ++) {
      if (i == (matchers.length-1)){
        regWord += matchers[i].keyword
      } else {
        regWord +=  matchers[i].keyword+ "|"
      }
  }
  return regWord;
}

// matchers のMap化
const matchersToMap = (matchers) => {
  let l = {};
  for (let i = 0; i < matchers.length; i ++) {
    l[matchers[i].keyword] = matchers[i];
  }
  return l;
}

```

#### matchersToRegWord
スプレッドシートから取得したマッチさせたいキーワードリストから、マッチさせるための正規表現を作成しています。
`A|B|C|D`

以下のA or B or C or Dがあった場合はマッチするようになります。

#### matchersToMap
計算量を減らすために、マッチさせたいキーワードのキーマップを作成します。

```
let data = matchersToMap(matchers)
data[keyword]で一致するmatcherが取得できるようになります
```


### 実行関数と、全コード

main()を実行するとフォルダ内にあるドキュメントに対して実行されるようになっています。


```js
function main() {
    const m = matchers(); 
    const files = getFilesById("下準備で保持したフォルダID");
    for (var i = 0; i < files.length; i ++) {
          review(files[i][1], m);
    }
}


// ドキュメントのIDとマッチさせたいキーワードの一覧を引数として実行
const review = (id, matchers) => {
  let m = matchersToMap(matchers);
  var body = DocumentApp.openById(id).getBody();
  var asText = body.asText();
  var text = asText.getText();

  // マッチさせる正規表現
  var regexp = new RegExp(matchersToRegWord(matchers), 'g');
  var pos = 0;
  var posN = 0;

  // マッチした単語がなくなるまで
  while ((arr = regexp.exec(text)) !== null) {
    const matcher = m[arr];
    if (matcher == null) {
      continue
    }
    // 更新処理
    posN = body.asText().getText().indexOf(matcher.keyword, pos);
    if (posN !== -1) {
      const start = posN;
      const end = posN + arr[0].length  - 1 ;
      // 下線
      asText.setUnderline(start, end, true);
      // 背景に色を付ける
      asText.setBackgroundColor(start, end, matcher.color);
      // 補助リンク
      asText.setLinkUrl(start, end, matcher.link);
    }
    // 現在の位置を更新
    pos = regexp.lastIndex;
  }
}

const getFilesById = (id) => {
  //idを取得するフォルダの指定
  const folderId = DriveApp.getFolderById(id);
  //指定したフォルダ内のすべてのファイルを格納
  const files = folderId.getFiles();

  //データを格納する配列の宣言
  const arr = [];

  // 更新日が5分以内の記事だけ抽出
  let rangeTime =new Date();
  rangeTime.setMinutes(rangeTime.getMinutes() - 5);

  //2次元配列として追加
  //フォルダ内のすべてのファイルについて実行
  while (files.hasNext()) {
    //すべてのファイルから１つ取り出し
    const file = files.next();
    // google document以外無視
    if (file.getMimeType() != "application/vnd.google-apps.document") {
      continue;
    }
    // スルー
    if (file.getLastUpdated().getTime() < rangeTime.getTime()){
      continue;
    }
    //配列にファイルのデータを追加
    //getName：ファイルの名前、getId：ファイルのID、getUrl:ファイルのURL
    arr.push([file.getName(),file.getId(),file.getUrl()]);
  }
  return arr;
};

class matcher {
    constructor(keyword,color, link){
      this.keyword = keyword;
      this.color = color;
      this.link = link;
    }
}

const matchers = () => {
    const app = SpreadsheetApp.openById("下準備3で保持しておいたスプレッドシートのID");
    const sheet = app.getSheetByName("スプレッドシートのシート名");
    const range = sheet.getRange(2, 1, sheet.getLastRow() - 1, 3);

    var list = [];
    for(var row = 1; row <= range.getNumRows(); row++) {
      const keyword = range.getCell(row, 1).getValue();
      const color = range.getCell(row, 2).getValue();
      const link = range.getCell(row, 3).getValue();
      list.push(new matcher(keyword, color, link));
    }

    return list;
}

// regexp
const matchersToRegWord = (matchers) => {
  let regWord = ""
  for (var i = 0; i < matchers.length; i ++) {
      if (i == (matchers.length-1)){
        regWord += matchers[i].keyword
      } else {
        regWord +=  matchers[i].keyword+ "|"
      }
  }
  return regWord;
}

// matchers のhash化
const matchersToMap = (matchers) => {
  let l = {};
  for (let i = 0; i < matchers.length; i ++) {
    l[matchers[i].keyword] = matchers[i];
  }
  return l;
}
```

## Google Driveを監視させて、自動実行させる
本当は、ファイル追加・変更でGASを動かしたかったのですが、以下の理由から、5分に一回実行するように設定します
- GASのトリガーでは、時間トリガーしかない
- Googleからのイベントフックを受け口が必要で、実装コストが高い
- 厳密にリアルタイムで反映させる必要はない

![](https://storage.googleapis.com/zenn-user-upload/b638c57b50887021d40e34c0.png)


## 実行結果
![](https://storage.googleapis.com/zenn-user-upload/e4bf18a89512f62765c44c00.png)

## 最後に
自動でチェックするスクリプトあれば、人での漏れが格段に減ると思います！
GASめちゃくちゃ便利でした
