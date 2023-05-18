---
title: "工数と影響範囲を抑えながら、GAEからCloud Runに移行した話"
emoji: "🔦"
type: "tech"
topics: ["gae","cloudrun"]
published: false
---

# はじめに
[Unlace](https://www.unlace.net/?utm_campaign=unlace_f_tech_zenn)でバックエンドエンジニアをしている栗栖です。
バックエンドAPIをGoogle App Engine(以後GAE) からCloud Runにダウンタイム0で移行しました。　　
API移行の理由と、具体的に工数と影響範囲を抑えるよう工夫しながら移行した内容についてまとめます。
また、移行するにあたってつまづいた点も紹介します。

# この記事で伝えたいこと
- GAEからCloud Runに工数と影響範囲を抑えながら移行する
- Cloud Runに移行する時につまづいた点と解決策


# なぜCloud Runに移行したのか
UnlaceのバックエンドはGAEのStandard環境で構築されています。

4月末にChatGPTを利用した**Searchlight**という機能では、リアルタイムでの応答を実現するためのストリーミングが必要でした。  
しかし、GAEだとストリーミングに[対応していません。](https://cloud.google.com/appengine/docs/standard/java-gen2/how-requests-are-handled?hl=ja#streaming_responses)
実際に、GAEでSSEを試すと、チャンクごとに送られず、単一のHTTPレスポンスとして送信されてしまいます。

そのため、GAEから別のサービスに乗り換える必要がありました。

@[tweet](https://twitter.com/unlace_net/status/1651110511604555777)
(Searchlightの詳細が知りたい方は、[こちらの記事](https://zenn.dev/yuto_iwashita/articles/gpt-searchlight)をご覧ください。)

ストリーミングだけであれば、GCEやGKS等でも実現できますが、以下の理由により、Cloud Runに移行することにしました。
## 移行コスト
機能の実装・開発のスケジュールに余裕がなかったため、インフラの移行には、なるべく時間的コストを抑えることが必須でした。  
GCEやGKSだと、インフラ環境の構築で時間がかかってしまうため、なるべくGAEと構成の近いCloud Runを選択しました。
また、Cloud Runであれば、別で利用しているCloud TasksやCloud Schedulerの基本的な構成は変えず(以下で移行手順で説明)、影響範囲も小さく移行できることもメリットの一つでした。

## 運用コスト
運用としてGAEはPaasで、運用コストは高くありませんでした。
GCEは、仮想マシン側の管理まで必要になり、コード以外の範囲が監視対象になるので、GAEに比べて運用コストが高くなります。
GKSも、k8sとしての運用コストが別に発生するため、GAEに比べて運用コストが高くなります。
運用コストとしても、Cloud RunはDockerfileを用意すれば、他はGAEと変わらないため、一番良いと判断しました。


また、GAEからCloud Runに移行することで、以下のメリットも得られると考えました。
## 言語バージョンの柔軟性
StandardのGAEでは、言語のバージョンに制限があります。  
UnlaceではGo言語をバックエンドに利用していますが、StandardのGAEだと、2023年初旬まではGoの最新バージョンが1.16だったため、Genericsの導入が遅れたという経緯があります。
Cloud Runであれば、このような制限がないため、柔軟に開発環境を選択することができるようになりました。

## 環境構成の更新の分離性
GAEでは`app.yaml`で記載された構成を変更する際、コードも全て再度デプロイする必要がありました。  
これだと、環境変数などのインスタンスの構成だけ変更したい時でも時間がかかり、面倒でした。

Cloud Runであれば、構成ファイルの更新だけを分離して反映されることができます。


# 移行の流れ
全体のフローとしては、以下記事に記載されているフローと同じになります。
あらかじめCloud Runをデプロイしたあと、
前段のロードバランサーの向き先をGAEからCloud Runに切り替えるという流れです。

こちらの記事とても参考にさせていただきました。ありがとうございます。
https://zenn.dev/team_zenn/articles/migrate-appengine-to-cloudrun

以下では、実際に、GAEの既存のコードや仕組みを利用して、工数と影響範囲を抑えながら移行した方法を説明します。

## Cloud Runの環境変数の設定

GCPのコンソール上で環境変数の設定は可能ですが、手動で対応するのはとても大変ですし、ミスを起こしやすいと思います。

そのためGAEの設定をそのままCloud Runに移すスクリプトを作成しました。
`app.yaml`の環境変数を、gcloudコマンドのservice update でenvを更新します。  

こうしておけば、既存の`app.yaml`で設定している環境をそのままCloud Runに反映することができます。

最初は`service.yaml`自体をRepositoryで管理することも検討しましたが、
`service.yaml`は全てのインフラ構成の設定が入っていて、変更の必要のない設定も多いため、環境変数だけを管理するようにしました。

シークレットに関しては、GAEの頃から、[berglas](https://github.com/GoogleCloudPlatform/berglas)を利用していたため、berglasの設定をそのまま利用しています。


```go

type AppYaml struct {
	Envs map[string]string `yaml:"env_variables"`
}

func GetEnvFromAppYaml() (map[string]string, error) {
	yamlFileName := "{GAEのapp.yaml}"
	filename, err := filepath.Abs(yamlFileName)
	if err != nil {
		return nil, err
	}
	yamlFile, err := ioutil.ReadFile(filename)
	if err != nil {
		return nil, err
	}
	y := new(AppYaml)
	if err := yaml.Unmarshal(yamlFile, &y); err != nil {
		return nil, err
	}
	return y.Envs, nil
}


func UpdateEnv() error {
    envMap := GetEnvFromAppYaml()

    var envVarsList []string
    for key, value := range envMap {
    	envVarsList = append(envVarsList, fmt.Sprintf("%s=%s", key, value))
    }
	
    envVarsStr := strings.Join(envVarsList, ",")
    if err := exec.Command("gcloud", "run", "services", "update", "unlace-api", "--update-env-vars", envVarsStr).Run(); err != nil {
    	return err
    }
    return nil
}


```

## Cloud Tasksの移行
今までGAEで利用していたqueue.yamlは特に変更は必要ありませんでした。
変更点としては、GAEの時はApp Engineターゲットを利用していたので、APIのコード上で、HTTP(s)ターゲットに変更します。

```go
    req := &tasks.CreateTaskRequest{
		Parent: createQueuePath(queueID),
		Task: &tasks.Task{
			ScheduleTime: restartAt,
			Name:         "{taskName}",
			MessageType: &tasks.Task_HttpRequest{
				HttpRequest: &tasks.HttpRequest{
					HttpMethod: method,
					Body:       body,
					Url:        fmt.Sprintf("%s/%s", env.AppURL(), path),
					..., // 他の設定
				},
			},
		},
	}

```

あとで後述しますが、検証ヘッダーも更新が必要です。


## Cloud Schedulerの移行
GAEでは、`App Engine HTTP` をターゲットに設定していたので、HTTPターゲットに変更が必要でした。  
なるべく影響反映を小さくするために、cron.yamlの構成をそのまま流用するスクリプトを作成します。

前提として、既存のcron.yamlファイルは以下のようにGAE向けの設定になっています。
schedule等はそのまま流用できるのですが、 HTTPターゲットでのジョブに名前を設定する必要があるため、追加作業として各Jobにnameを追加します。

※ [公式](https://cloud.google.com/scheduler/docs/configuring/cron-job-schedules?hl=ja)では、以下のように記述があるため、 App Engine cronの記法は推奨されていませんが、サポートはされていますので、別のタイミングで、unix-cronの記法に変更が必要ですが、今回はそのまま流用しました。
```
unix-cron に基づく形式で指定します。ジョブを 1 日に複数回実行するか、または具体的な日と月に実行するようにスケジュールを定義できます。
(おすすめしませんが、従来の App Engine cron 構文は既存のジョブで引き続きサポートされます。)
```

既存のcron.yamlの例
```yaml
cron:
  - description: "hogehoge"
    url: /api/cron/hogehoge
    schedule: every day 14:00
    target: default
    // name: "hogeHogeJob"
```


以下Cloud Schedulerの移行スクリプトのフローです。
1. `cron.yaml`からジョブを一覧取得
2. 既存のHTTPターゲットschedulerのジョブを取得
3. 新規のジョブは作成
4. 既に登録してあるジョブは値が更新された時、更新
5. 既に登録しているジョブが、cron.yamlに存在しない時は、pause


```go

type CronYaml struct {
	Cron []struct {
		URL         string `yaml:"url"`
		Schedule    string `yaml:"schedule"`
		Target      string `yaml:"target"`
		Timezone    string `yaml:"timezone"`
		Description string `yaml:"description"`
		Name        string `yaml:"name"`
	} `yaml:"cron"`
}

type schedulerAction string

const (
	schedulerActionCreate schedulerAction = "create"
	schedulerActionUpdate schedulerAction = "update"
	schedulerActionPause  schedulerAction = "pause"
)

func executeJob(client *cloudscheduler.Service, action schedulerAction, parent, jobName string, targetURL string, schedule string, timezone string, description string) error {
	if timezone == "" {
		timezone = "UTC"
	}
	job := &cloudscheduler.Job{
		Name: jobName,
		HttpTarget: &cloudscheduler.HttpTarget{
			Uri:        targetURL,
			HttpMethod: "GET",
		},
		Description: description,
		Schedule:    schedule,
		TimeZone:    timezone,
	}

	switch action {
	case schedulerActionCreate:
		_, err := client.Projects.Locations.Jobs.Create(parent, job).Do()
		if err != nil {
			return fmt.Errorf("failed to create %v: %v", jobName, err)
		}
	case schedulerActionUpdate:
		_, err := client.Projects.Locations.Jobs.Patch(jobName, job).Do()
		if err != nil {
			return fmt.Errorf("failed to update %v: %v", jobName, err)
		}
	case schedulerActionPause:
		_, err := client.Projects.Locations.Jobs.Pause(jobName, nil).Do()
		if err != nil {
			return fmt.Errorf("failed to pause %v: %v", jobName, err)
		}
	}
	fmt.Printf("%s %s done.\n", jobName, action)
	return nil
}

func scheduler()error {
	yamlFile, err := os.ReadFile("cron.yaml")
	if err != nil {
		return err
	}
	y := &CronYaml{}
	if err := yaml.Unmarshal(yamlFile, &y); err != nil {
		return err
	}

	ctx := context.Background()
	client, err := cloudscheduler.NewService(ctx)
	if err != nil {
		return fmt.Errorf("failed to create Cloud Scheduler client: %v", err)
	}

	
	// 既存で設定されているJobを取得
	parent := fmt.Sprintf("projects/%s/locations/%s", env.GoogleCloudProject(), env.GoogleCloudProjectLocation())
	itemsMap := map[string]*cloudscheduler.Job{}
	nextPageToken := ""
	for {
		res, err := client.Projects.Locations.Jobs.List(parent).Context(ctx).PageToken(nextPageToken).Do()
		if err != nil {
			return err
		}
		if res.HTTPStatusCode < 200 || 300 <= res.HTTPStatusCode {
			return fmt.Errorf("failed to list jobs: %v", res.HTTPStatusCode)
		}
		for _, v := range res.Jobs {
			itemsMap[v.Name] = v
		}
		if res.NextPageToken == "" {
			break
		}
		nextPageToken = res.NextPageToken
	}
	
	// cron.yamlに記述されている設定で変更があるジョブの反映
	for _, cron := range y.Cron {
		jobName := fmt.Sprintf("%s/jobs/%s", parent, cron.Name)
		job := itemsMap[jobName]
		switch {
		// まだ作成されていないjobは作成
		case job == nil:
			if err := executeJob(client, schedulerActionCreate, parent, jobName, fmt.Sprintf("%s%s", env.Cloud RunDefaultAppURL(), cron.URL), cron.Schedule, cron.Timezone, cron.Description); err != nil {
				return err
			}
			delete(itemsMap, jobName)
		case job != nil:
			if job.Schedule != cron.Schedule || job.TimeZone != cron.Timezone || job.Description != cron.Description || job.HttpTarget.Uri != fmt.Sprintf("%s%s", env.Cloud RunDefaultAppURL(), cron.URL) {
				if err := executeJob(client, schedulerActionUpdate, parent, jobName, fmt.Sprintf("%s%s", env.Cloud RunDefaultAppURL(), cron.URL), cron.Schedule, cron.Timezone, cron.Description); err != nil {
					return err
				}
			} else {
				fmt.Printf("%s no change.\n", job.Name)
			}
			delete(itemsMap, jobName)
		}
	}
	
	// cron.yamlに存在しないジョブをpauseする
	for _, v := range itemsMap {
		if err := executeJob(client, schedulerActionPause, parent, v.Name, "", "", "", ""); err != nil {
			return err
		}
	}
	return nil

}
```



## 当日の移行作業：ロードバランサーの向き先でCloud Runに変更する
元からUnlaceでは前段にロードバランサーがあるため、向き先をGAEからCloud Runに変更するだけでよいので、当日の実際の移行作業は。
Cloud Runと紐づくServerless NEG/バックエンドサービスを作成し、ロードバランサーの向き先をCloud Runに切り替えます。 
- GAE
![](/images/gae-migrate-cloudrun/gae.png)
- Cloud Run
![](/images/gae-migrate-cloudrun/cloudrun.png)



# Cloud Run導入にあたってつまづいた点
## 最小インスタンス数
GAEと比べてCloud Runではスピンアップまでの時間がかかるため、コスト削減による最小インスタンスを0にしていると、インスタンス起動により、レイテンシーが悪化します。  
少なくともインスタンスは1以上で設定するのをおすすめします。

## 最大インスタンス数
dev環境での動作確認時、Cloud Runでは最大インスタンスを3に設定していたのですが、動作確認をしているとポツポツとエラーを返すようになっていました。  
原因を掴むのにかなり時間がかかりましたが、GCPのUI上に注意書きがありましたorz
以下にもある通り、最大インスタンスは4以上にしました。
![](/images/gae-migrate-cloudrun/maxinstance.png)


## CloudTaskへのリクエストタイムアウトが30sを超えるとエラーになること
これはCloud Runに限らずかつGo言語のパッケージで起きたことですが、ご紹介します。  
CloudTaskをバックエンドからリクエストをする時、親コンテキストのタイムアウトが30sを超えていると、エラーになってしまいます。
```markdown
rpc error: code = InvalidArgument desc = The request deadline is xxxx. The deadline cannot be more than 30s in the future.
```
移行対応時に、CloudTasksを処理するAPIを明示的に5分のタイムアウトを設定したため、このエラーが発生しました。

対応としては、[issue](https://github.com/googleapis/google-cloud-go/issues/1577)にもある通り、Cloud Tasksを呼び出す時はTimeoutを30s以内に設定しました。

```go
// ctxのタイムアウトが30sを超えているとエラーになる
func task(ctx context.Context) {
    client, err := cloudtasks.NewClient(ctx)
	if err != nil {
		return nil, err
	}
	defer client.Close()
    req := &tasks.CreateTaskRequest{
		Parent: createQueuePath(queueID),
		Task: &tasks.Task{
        ...
        },
	}
	task, err := client.CreateTask(ctx, req)
	if err != nil {
		return nil, err
	}
}
```

## Cloud Scheduler/Cloud Tasksのリクエスト検証ヘッダー
今まで、AppEngineという前提での検証チェックになっていたのでうまくリクエストが通りませんでした。   
それぞれ、検証するヘッダー名を変更する必要があります。

|  名前  |  移行前  |　移行後　|
| -- | ---- | ---- |
|  Cloud Scheduler  |  `X-Appengine-Cron` | `X-CloudScheduler` |
|  Clout Tasks |  `X-Appengine-Cron`  | `X-CloudTasks-TaskName` |

# まとめ
GAEの既存設定を利用することで、工数と影響範囲を抑えてCloud Runへの移行し、予定通りに機能リリースすることができました。

これによりストリーミングが実現できただけではなく、 
インスタンスに対しても、細かい設定ができるようになり、より柔軟な運用ができるようになりました。  


# 最後に
Unlaceはクライエントとカウンセラー双方がよりよい体験を得られるサービスを提供していくため、様々な技術に挑戦しています。
そして、2023年5月現在、エンジニアは2人で開発しており、 まだまだたくさんのエンジニアが必要です！
ユーザの価値貢献につながるサービスを一緒に作りませんか？
https://job.unlace.net/
