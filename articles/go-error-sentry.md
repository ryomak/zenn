---
title: "Go: 独自エラーを整形してSentryに送信する"
emoji: "🚓"
type: "tech" 
topics: ["Go","Sentry"]
published: true
---

## はじめに
Goのアプリケーションで独自エラー情報を整形してSentryに送るTipsを紹介します。
前提として[https://github.com/getsentry/sentry-go](https://github.com/getsentry/sentry-go)を使うことを想定しています。

## スタックトレースを送る
エラー発生元のスタックトレースを送るためには大きく分けて2つステップが必要です。
1. エラーにスタックトレースを追加する
2. `sentry-go` で決められたメソッドを実装するエラーを作成する

では、それぞれ説明します。

### 1. エラーにスタックトレースを追加する
Goではデフォルトでエラーにスタックトレースが付与されません。
そのため、独自エラーやエラーハンドリングライブラリを使ってスタックトレースを管理する必要があります。

スタックトレースを付与できる便利なライブラリはいくつかあります。
個人的に`failure`は使いやすくて好きです。
[https://github.com/morikuni/failure](https://github.com/morikuni/failure)
[https://github.com/cockroachdb/errors](https://github.com/cockroachdb/errors)


独自エラーでスタックトレースを持たせる場合は、`runtime.Callers`を使ってプログラムカウンターを取得して、`runtime.CallersFrames`を使って関数の情報を取得できます。
この関数の情報をエラーに保存しておき、スタックトレースとして出力します。

```go
type Frame []uintptr

func caller(skip int) Frame {
	f := [16]uintptr{}
	n := runtime.Callers(skip+1, f[:])
	return f[:n]
}

func (f Frame) location() (function, file string, line int) {
	frames := runtime.CallersFrames(f[:])
	if _, ok := frames.Next(); !ok {
		return "", "", 0
	}
	fr, ok := frames.Next()
	if !ok {
		return "", "", 0
	}
	return fr.Function, fr.File, fr.Line
}
```

**独自エラーの例**
独自エラーにframeを追加して、customErrorが生成された位置をframeに埋め込んでおく
```go
type customError struct {
	message string

	// 根本のエラー
	cause error

	// 埋め込んでおく
	frame Frame
}

func newCustomError(msg string) *customError {
	e := new(customError)
	e.message = msg
	e.frame = caller(1)
	return e
}
```


### 2.`sentry-go` で決められたメソッドを実装するエラーを作成する
`sentry-go` では、スタックトレースを出力するために、`sentry.ExtractStacktrace` を内部で使っています。　　 
内部には特定のライブラリのエラーを前提として決め打ちでメソッドを呼び出す処理があります。
参考: [https://github.com/getsentry/sentry-go/blob/master/stacktrace.go](https://github.com/getsentry/sentry-go/blob/master/stacktrace.go#L83-L87)
```go
// https://github.com/getsentry/sentry-go/blob/master/stacktrace.go#L83-L87
func extractReflectedStacktraceMethod(err error) reflect.Value {
	errValue := reflect.ValueOf(err)

	// https://github.com/go-errors/errors
	methodStackFrames := errValue.MethodByName("StackFrames")
	if methodStackFrames.IsValid() {
		return methodStackFrames
	}

	// https://github.com/pkg/errors
	methodStackTrace := errValue.MethodByName("StackTrace")
	if methodStackTrace.IsValid() {
		return methodStackTrace
	}

	// https://github.com/pingcap/errors
	methodGetStackTracer := errValue.MethodByName("GetStackTracer")
	if methodGetStackTracer.IsValid() {
		stacktracer := methodGetStackTracer.Call(nil)[0]
		stacktracerStackTrace := reflect.ValueOf(stacktracer).MethodByName("StackTrace")

		if stacktracerStackTrace.IsValid() {
			return stacktracerStackTrace
		}
	}

	return reflect.Value{}
}
```

上記のコードは、決め打ちでメソッドを呼び出せるかチェックしているため、同じメソッドをエラーに実装する必要があります。
このためsentryに対応していないエラーハンドリングライブラリを使っている場合は、独自にエラーを作成し、メソッドを実装する必要があります。

今回は `StackTrace` メソッドを実装して、エラーからスタックトレースを取得できるようにしてみます 
```go
type customError struct {
    message string
    frame Frame
}

func (c *customError) StackTrace() []uintptr {
    return c.frame
}
```

## イベントの形を整形する
エラーをSentryに送信する際は以下のメソッドを呼び出しますが、カスタムエラーの場合は、sentryのType(エラーのタイトル)が型名になってしまいます。
```go
sentry.CaptureException(err)
```

### グローバルでエラーを整形する
Sentryの初期化時に、BeforeSendを使って、エラーのTypeをエラーメッセージに変更することができます
```go
    err := sentry.Init(sentry.ClientOptions{
		Dsn:              "hogehoge"
		Environment:      "local",
		BeforeSend: func(event *sentry.Event, hint *sentry.EventHint) *sentry.Event {
			// エラー意外にも通常のメッセージもこの処理に入るので、エラーのみ処理する
			if hint.OriginalException == nil {
				return event
			}

			for i := range event.Exception {
				exception := &event.Exception[i]
				// tracker.Errorのタイトルを書き換える
				if strings.Contains(exception.Type, "customError") {
					// Typeがタイトルに当たる
					exception.Type = hint.OriginalException.Error()
				}
			}
			return event
		},
	})
```

ちなみに、`BeforeSend` でnilを返すとSentryにイベントを送信しないようにできるので、特定の条件のみ送らないというのもここでもハンドリングが可能です

### イベントをカスタムで設定する
`CaptureException` を使わずに独自でイベントを作成して送信することもできます
```go
event := sentry.NewEvent()
event.Type = "customError"
sentry.CaptureEvent(event)
```



## 作ってみた
https://github.com/ryomak/serrs
Sentryにエラーを送信できる独自エラーを作ってみました。

### エラーの初期化
```go
var InvalidParameterError = serrs.New(serrs.DefaultCode("invalid_parameter"),"invalid parameter error")
var CustomError = serrs.Wrap(
    err, 
    serrs.WithCode(serrs.DefaultCode("custom_error")),
    serrs.WithMessage("custom error"),
)
```
### 例
https://github.com/ryomak/serrs/tree/main/example/send_sentry
### タイトル
一番根本のエラーメッセージがTypeになるようにしてます
![](/images/go-error-sentry/sentry_title.png)
### スタックトレース
発生したエラーのスタックトレースが出力されています
![](/images/go-error-sentry/sentry_stacktrace.png)
### 追加データ
エラーのツリーで追加したデータが一覧で表示されます
![](/images/go-error-sentry/sentry_customdata.png)

### おまけ
- `fmt.Printf("%+v",err)`で、Wrapしたエラーのスタックトレースが出力されます
```go
if err := DoSomething(); err != nil {
    // This point is recorded
    return serrs.Wrap(err)
}

fmt.Printf("%+v",err)

// Output Example:
// - file: ./serrs/format_test.go:22
//   function: github.com/ryomak/serrs_test.TestSerrs_Format
//   msg: 
// - file: ./serrs/format_test.go:14
//   function: github.com/ryomak/serrs_test.TestSerrs_Format
//   code: demo
//   data: {key1:value1,key2:value2}
// - error1
```

## 最後に
Goのアプリケーションで独自エラー情報を整形してSentryに送るTipsを紹介しました。
独自エラーを作成する方の参考になれば幸いです。
