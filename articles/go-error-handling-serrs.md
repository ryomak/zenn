---
title: "Goでスタックトレースを持つエラーライブラリを実装した"
emoji: "🐝"
type: "tech" 
topics: ["Go","Sentry"]
published: true
---

## はじめに
Goにはエラー処理を行うための標準パッケージがありますが、2024年4月現在、エラーにスタックトレースを付与する機能はありません。

ここの背景に関しては、以下の記事がとても勉強になりました。
https://methane.hatenablog.jp/entry/2024/04/02/Go%E3%81%AEerror%E3%81%8C%E3%82%B9%E3%82%BF%E3%83%83%E3%82%AF%E3%83%88%E3%83%AC%E3%83%BC%E3%82%B9%E3%82%92%E5%90%AB%E3%81%BE%E3%81%AA%E3%81%84%E7%90%86%E7%94%B1

スタックトレース有りの便利なライブラリはいくつかあります。
個人的にアプリケーションを作る時は、シンプルなfailureを使うことが多いです。
[https://github.com/morikuni/failure](https://github.com/morikuni/failure)
[https://github.com/cockroachdb/errors](https://github.com/cockroachdb/errors)


今回はカスタムしなくても良い感じにエラーを整形して、Sentryで確認したいと思い、 
自分が欲しい機能のみを搭載したシンプルなエラーハンドリングライブラリを作りました。

独自エラーを作ってハンドリングしている方の参考になれば幸いです。

## 実現したかったこと
- エラーを簡単に作成できる
- エラーからスタックトレースを付与できる
- エラーにカスタムデータを追加できる
- スタックトレースや追加データを整形してSentryに送信できる

## 完成したライブラリ
https://github.com/ryomak/serrs

## 使い方
### エラーの作成
Codeとメッセージでエラーを作成できます
```go
var HogeError = serrs.New(serrs.StringCode("hoge"), "hogehoge")
```

### スタックトレースが自動追加される
`Wrap`すると自動でスタックトレースが追加されます
```go
if err := DoSomething(); err != nil {
    return serrs.Wrap(err)
}

// serrs.WithXXX関数を使って追加情報を付与することもできます
if err := DoSomething(); err != nil {
    return serrs.Wrap(err,serrs.WithMessage("wrap error"),serrs.WithData(serrs.DefaultCustomData{"key1": "value1"}),)
}
```

### スタックトレースを出力
スタックトレースがWrapごとに出力されます
```go
fmt.Printf("%+v",err)

// Output Example:
// - file: ./serrs/format_test.go:22
//   function: github.com/ryomak/serrs_test.TestSerrs_Format
//   msg: 
// - file: ./serrs/format_test.go:14
//   function: github.com/ryomak/serrs_test.TestSerrs_Format
//   code: demo
//   data: {key1:value1}
// - error1
```

### Sentryに送信
Sentryにエラーを送信するには、`GenerateSentryEvent`でエラーをSentry用のイベントに変換して、`CaptureEvent`で送信します
```go
event := serrs.GenerateSentryEvent(err)
sentry.CaptureEvent(event)
```

## Sentryに送信されるエラー
### example
https://github.com/ryomak/serrs/tree/main/example/send_sentry
### タイトル
カスタムエラーは、通常Typeには型名が入ってしまうのですが、一番最初のエラーメッセージががTypeになるようにしてます
![](/images/go-error-handling-serrs/sentry_title.png)
### スタックトレース
Wrapした箇所がリストで出力されます
![](/images/go-error-handling-serrs/sentry_stacktrace.png)
### 追加データ
エラーのツリーで追加したデータが一覧で表示されます
![](/images/go-error-handling-serrs/sentry_customdata.png)

## 内部実装
serrsがどのようにエラーを管理しているかを簡単に説明します。

### simpleError構造体
simpleErrorはtree構造になっており、Wrapするたびにcauseに元のエラーを含めることで親子関係を持たせています。
独自エラーで保持しているデータ構造です。
```go
// simpleError is a simple implementation of the error interface.
type simpleError struct {
	// message is the error message
	message string

	// code is the error code
	// optional
	code Code

	// cause is the cause of the error
	cause error

	// frame is the location where the error occurred
	frame Frame

	// data is the custom data attached to the error
	data CustomData
}
```

### Wrap
runtime.Callersを使って位置情報をerrorのFrameとして追加しています
```go
func Wrap(err error, ws ...errWrapper) error {
	if err == nil {
		return nil
	}
	e := newSimpleError("", 1)
	e.cause = err
	for _, w := range ws {
		w.wrap(e)
	}
	return e
}

func newSimpleError(msg string, skip int) *simpleError {
	e := new(simpleError)
	e.message = msg
	e.frame = caller(skip + 1)
	return e
}

func caller(skip int) Frame {
    var s Frame
    runtime.Callers(skip+1, s.frames[:])
    return s
}

type Frame struct {
	frames [3]uintptr
}

// caller returns a Frame that describes a frame on the caller's stack.
func caller(skip int) Frame {
	var s Frame
	runtime.Callers(skip+1, s.frames[:])
	return s
}

// location returns the function, file, and line number of a Frame.
func (f Frame) location() (function, file string, line int) {
	frames := runtime.CallersFrames(f.frames[:])
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

### 詳細出力
fmt.Formatterを実装して、スタックトレースや追加データの出力をカスタマイズします。
```go
// Format implements fmt.Formatter interface
func (s *simpleError) Format(state fmt.State, v rune) {
	formatError(s, state, v)
}

// formatErrorの内部で呼び出す
// https://github.com/ryomak/serrs/blob/main/format.go
func (s *simpleError) printerFormat(p printer) error {
	var message string
	if s.code != nil {
		message += fmt.Sprintf("code: %s\n", s.code.ErrorCode())
	}
	if s.message != "" {
		message += fmt.Sprintf("msg: %s\n", s.message)
	}
	if s.data != nil {
		message += fmt.Sprintf("data: %v", s.data)
	}

	// print stack frame
	s.frame.format(p)

	// print message
	p.Print(message)

	// 再帰的に親のエラーを出力
	return s.cause
}
```


### SentryでWrapしたerrorからスタックトレースを出力する
sentry-goでは、スタックトレースを出力するために、`sentry.ExtractStacktrace`を使っています。
内部では、以下のように決め打ちでメソッドを呼び出しています。
https://github.com/getsentry/sentry-go/blob/master/stacktrace.go#L83-L87
```go
    // https://github.com/pkg/errors
	methodStackTrace := errValue.MethodByName("StackTrace")
	if methodStackTrace.IsValid() {
		return methodStackTrace
	}
```

上記のメソッドが呼ばれるように、simpleErrorにもStackTraceメソッドを実装しています。
```go
func (s *simpleError) StackTrace() pkgErrors.StackTrace {

	f := make([]pkgErrors.Frame, 0, 30)

	if next := asSimpleError(s.cause); next != nil {
		f = append(f, next.StackTrace()...)
	}

	// frames 0: newSimpleError() frames 1: frame0+1
	f = append(f, pkgErrors.Frame(s.frame.frames[1]))

	return f
}
```

### Sentryへ送信するイベントの生成
```go
// GenerateSentryEvent is a method to generate a sentry event from an error
func GenerateSentryEvent(err error, ws ...sentryWrapper) *sentry.Event {
	if err == nil {
		return nil
	}
	errCode, ok := GetErrorCode(err)
	if !ok {
		errCode = StringCode("unknown")
	}
	event := sentry.NewEvent()
	event.Level = sentry.LevelError
	event.Exception = []sentry.Exception{{
		Value:      err.Error(),
		// Typeにはエラーの親のメッセージを入れる
		Type:       Origin(err).Error(),
		Stacktrace: sentry.ExtractStacktrace(err),
	}}
	event.Contexts = map[string]sentry.Context{
		"error detail": {
			// エラーの階層データを出力
			"history": StackedErrorJson(err),
			"code":    errCode.ErrorCode(),
		},
	}

	for _, w := range ws {
		w.wrap(event)
	}

	return event
}
```


## まとめ
シンプルなエラーハンドリングライブラリを作成しました。
車輪の再開発感は否めないですが、独自エラーを利用しているプロダクトも一定数あるかと思うので、Sentryへのエラー出力や
スタックトレースの管理で悩まれている方にとって 少しでも参考になれば幸いです。