---
title: "Go版のLangChainとWeaviateを使って、Q&A機能を作ってみる"
emoji: "🧪"
type: "tech"
topics: ["go","LangChain","ChatGPT","Weaviate"]
published: true
---

## はじめに
Go版のLangChain(非公式)とWeaviateというVectorStoreを使って、Q&A機能を実装しました。


## 利用するリポジトリ
https://github.com/tmc/langchaingo/

## サンプルコード
https://github.com/ryomak/LangChain-go-example

```bash
$ go run main.go
=====================================
kind:
 html
question:
 Go1.21に追加された3つのbuilt-insはなんですか？
result:
  Go1.21で追加された新しいbuilt-insは、min、max、clear関数です。
=====================================
```

## Q&A機能の流れ
今回は以下のフローでQ&A機能を実装します
1. 前準備：あらかじめ、Q&Aで用いる事前データをベクトル化して保存する
2. ユーザの質問をベクトル化して、保存しておいたベクトルと類似度を計算する
3. 類似度が高いドキュメントをいくつか取得する
4. 取得したドキュメントをコンテキストとして、プロンプトに含めて質問する
5. GPTの出力を返す


## 環境変数
OpenAIのAPIキーを環境変数に設定します。
```bash
export OPENAI_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## Vector Store
ベクトルの保存と類似度検索を行うVectorStoreには[Weaviate](https://weaviate.io/)を利用します。
Weaviateは、Dockerイメージが提供されているので、サクッと試せます。

docker-compose.yml
```yaml
version: '3.4'
services:
  weaviate:
    image: semitechnologies/weaviate:1.19.9
    ports:
      - 8080:8080
    environment:
      QUERY_DEFAULTS_LIMIT: 25
      AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED: 'true'
      PERSISTENCE_DATA_PATH: '/var/lib/weaviate'
      DEFAULT_VECTORIZER_MODULE: 'none'
```

```bash
docker-compose up
```


### Classを作成する
Weaviateに保存するクラスを作成します。
クラスは、オブジェクトを格納するデータコレクションです。

プロパティには、textとnamespaceを定義します。
後述しますが、langchaingoではどちらも必須のプロパティになります。
```go
func main() {
	weaviateClient := weaviate.New(weaviate.Config{
		Host:   "localhost:8080",
		Scheme: "http",
	})
	ctx := context.Background()
	if err := weaviateClient.Schema().ClassCreator().WithClass(&models.Class{
		Class:       qa.WeaviateIndexName,
		Description: "qa class",
		VectorIndexConfig: map[string]any{
			"distance": "cosine",
		},
		ModuleConfig: map[string]any{},
		Properties: []*models.Property{
			{
				Name:        qa.WeaviatePropertyTextName,
				Description: "document text",
				DataType:    []string{"text"},
			},
			{
				Name:        qa.WeaviatePropertyNameSpaceName,
				Description: "namespace",
				DataType:    []string{"text"},
			},
		},
	}).Do(ctx); err != nil {
		panic(err)
	}
	fmt.Println("created")
}
```


### データを入稿する
langchaingoのdocumentLoaderはまだ未実装が多いのですが、
すでに実装済みの、HTMLのLoaderを使って、データ入稿するスクリプトを用意しました。

入稿スクリプト
```go
func main() {
	chain, err := qa.New()
	if err != nil {
		panic(err)
	}

	ctx := context.Background()

	file, err := os.Open("./script/insert_docs_html/qa.html")
	if err != nil {
		panic(err)
	}
	loader := documentloaders.NewHTML(file)
	docs, err := loader.LoadAndSplit(
		context.Background(),
		textsplitter.RecursiveCharacter{
			Separators:   []string{"\n\n", "\n", " ", ""},
			ChunkSize:    800,
			ChunkOverlap: 200,
		},
	)
	if err != nil {
		panic(err)
	}
	for _, v := range docs {
		if err := chain.AddDocument(ctx, qa.NameSpaceHTML, v.PageContent); err != nil {
			panic(err)
		}
	}
	fmt.Println("done")
}
```
入稿データ)
Go1.21のリリースノートのページをqa.htmlとして保存しています。
https://tip.golang.org/doc/go1.21



## インスタンスの生成
llmと文章のベクトル化に、OpenAIを利用します。
- indexName: Weaviateのクラスと一致します。
- textKey: Weaviateのtextプロパティと一致します。langchaingoで検索して類似したベクトルの元の文章が格納されています。
- nameSpaceKey: Weaviateのnamespaceプロパティと一致します。weaviateの1つのクラスで、複数のQ&Aを管理するために利用します。
```go
const (
    WeaviateIndexName = "QA_2023"
    WeaviatePropertyTextName      = "text"
    WeaviatePropertyNameSpaceName = "namespace"
)

type QA struct {
	llm   llms.LanguageModel
	store vectorstores.VectorStore
}

func New() (*QA, error) {
	llm, err := openai.New()
	if err != nil {
		return nil, err
	}
	e, err := embeddings.NewOpenAI()
	if err != nil {
		return nil, err
	}
	store, err := weaviate.New(
		weaviate.WithScheme("http"), // docker-composeの設定に合わせる
		weaviate.WithHost("localhost:8080"), // docker-composeの設定に合わせる
		weaviate.WithEmbedder(e),
		weaviate.WithIndexName(WeaviateIndexName),
		weaviate.WithTextKey(WeaviatePropertyTextName),
		weaviate.WithNameSpaceKey(WeaviatePropertyNameSpaceName),
	)
	if err != nil {
		return nil, err
	}
	return &QA{
		llm:   llm,
		store: store,
	}, nil
}
```

## 文章の追加
Weaviateに文章を追加します。  
```go
func (l *QA) AddDocument(ctx context.Context, namespace NameSpace, content string) error {
	return l.store.AddDocuments(ctx, []schema.Document{
		{
			PageContent: content,
		},
	}, vectorstores.WithNameSpace(string(namespace)))
}
```

## 質問の回答
質問を回答する処理です。  
```go
func (l *QA) Answer(ctx context.Context, namespace NameSpace, question string) (string, error) {
	prompt := prompts.NewPromptTemplate(
		`## Introduction 
あなたはカスタマーサポートです。丁寧な回答を心がけてください。
以下のContextを使用して、日本語で質問に答えてください。Contextから答えがわからない場合は、「わかりません」と回答してください。

## 質問
{{.question}}

## Context
{{.context}}

日本語での回答:`,

		[]string{"context", "question"},
	)

	combineChain := chains.NewStuffDocuments(chains.NewLLMChain(l.llm, prompt))

	result, err := chains.Run(
		ctx,
		chains.NewRetrievalQA(
			combineChain,
			vectorstores.ToRetriever(
				l.store,
				5,
				vectorstores.WithNameSpace(string(namespace)),
			),
		),
		question,
		chains.WithModel("gpt-4-0613"),
	)
	if err != nil {
		return "", err
	}
	return result, nil
}
```

### プロンプトテンプレート
プロンプトテンプレートは、回答の文章を生成するためのテンプレートです。
`RetrievalQA`を利用する場合は、デフォルトでは以下キーに設定した値がプロンプトに埋め込まれます。キーは独自に設定可能です。
- context: VectorStoreでの検索結果の文章
- question: 質問の文章

プロンプトテンプレートもデフォルトがあるので、以下のように短くすることも可能ですが、
日本語で回答させるために、プロンプトテンプレートから生成しています。
```go
result, err := chains.Run(
    ctx,
    chains.NewRetrievalQAFromLLM(
        l.llm,
        vectorstores.ToRetriever(
            l.store,
            5,
            vectorstores.WithNameSpace(string(namespace)),
        ),
    ),
    question,
    chains.WithModel("gpt-4-0613"),
)
```



## 実行コード
```go
package main

import (
	"context"
	"fmt"
	"github.com/ryomak/LangChain-go-example/qa"
)

func main() {
	qaBot, err := qa.New()
	if err != nil {
		panic(err)
	}
	ctx := context.Background()
	for _, v := range []struct {
		question  string
		nameSpace qa.NameSpace
	}{
		{
			question:  "Go1.21に追加された3つのbuilt-insはなんですか？",
			nameSpace: qa.NameSpaceHTML,
		},
	} {
		result, err := qaBot.Answer(ctx, v.nameSpace, v.question)
		if err != nil {
			panic(err)
		}

		fmt.Println("=====================================")
		fmt.Printf("kind:\n %s", v.nameSpace)
		fmt.Printf("question:\n %s", v.question)
		fmt.Printf("result:\n %s", result)
		fmt.Println("=====================================")
	}
}
```

結果
```bash
$ go run main.go
=====================================
kind:
 html
question:
 Go1.21に追加された3つのbuilt-insはなんですか？
result:
  Go1.21で追加された新しいbuilt-insは、min、max、clear関数です。
=====================================
```
うまく結果を取得できました。

## 最後に
Q&A機能をかなり簡単に作成することができました。  
langchaingoは、本家のPythonやJavaScript版に比べると、まだまだ機能が足りていないですが、
機能が増えていくにつれて、より多くの多様な応用が可能になると考えています。

また、Weaviateも簡単にベクトル検索ができるので、使い勝手もかなり良いな思いました。
