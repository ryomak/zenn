---
title: "SQLBoilerのちょっとしたTips集"
emoji: "🗄️"
type: "tech" 
topics: ["Go","SQLBoiler"]
published: true
---

## はじめに
https://github.com/volatiletech/sqlboiler
SQLBoilerは、スキーマに合わせたORMを生成するツールです。
READMEにも書かれていますが、意外と気づきづらい部分があったりするので、使い方から、ちょっとしたTips、ハマりポイントをまとめます。  
少しでも参考になれば幸いです。

## 前提
- MySQL
- 生成したコードは`model`パッケージに配置されているとします
- テーブルは以下を想定
```sql
CREATE TABLE `teams` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    
CREATE TABLE `users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(255) DEFAULT NULL,
  `team_id` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  CONSTRAINT `fk_users_teams` FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE `comments` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) DEFAULT NULL,
  `content` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  CONSTRAINT `fk_comments_users` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

## 1. カラムやテーブルは生成された変数を使う
生成されたコードには、テーブル名やカラム名が規則的に定義されています。
そのため、生成された変数を使って、コードを書くことができます。

- テーブル名
```go
// model.TableNames
model.TableNames.User
```

- カラム名
```go
// model.{Model}Columns
model.UserColumns.ID
```

- Where句
```go
// model.{Model}Where.{Column}.{Operator}
model.UserWhere.ID.EQ(1)
```
- 外部キー
```go
// model.{Model}Rels
UserRels.Teams
```


## 2. クエリ構築のための3つのアプローチ
なるべく型で縛っておいた方が安全なので、(1)を使うことをおすすめしますが、ケースバイケースで使い分けることができます。
### (1) テーブルごとに生成されたコードを使ったクエリ
```go
user, err := model.Users(
	model.UserWhere.ID.EQ(1),
).One(ctx, db)
```

### (2) クエリビルダーを使ったクエリ
```go
var users []*model.User
if := model.NewQuery(
    qm.From(model.TableNames.User), 
    qm.Where(model.UserColumns.Name+" = ?", "taro"),
).Bind(ctx, db, &users)
```

### (3) queries.Rawを使ったクエリ
```go
var users []*model.User
err := queries.Raw(
    "SELECT * FROM users WHERE name = ?",
    "taro",
).Bind(ctx, db, &users)
```

## 3 カラム推論(boil.Columns)の使いわけ: boil.Infer, boil.Graylist, boil.Blacklist, boil.Whitelist
Insert/Update/Upsertを呼び出す際に、挿入・更新すべきカラムを推論します。
その時の推論する挙動を制御するためのメソッドです。

| メソッド | 説明                                     |
| --- |----------------------------------------|
| Infer | デフォルト値がないカラムと、非ゼロのデフォルト値を持つカラムが追加されます。 |
| Whitelist | 指定したカラムのみ追加します。                        |
| Blacklist | Inferで選択されたカラムから、指定したカラムを除外します。        |
| Greylist | Inferで選択されたカラムに合わせて、指定したカラムを追加します。     |

```go
user.Insert(ctx, db, boil.Infer())
```

### 特別なカラム
`created_at`/`updated_at`カラムは、デフォルトの設定だと、Insert(),Update()の際に、よしなに値がセットされるようになっています。

```go
// Insertの内部処理
if !boil.TimestampsAreSkipped(ctx) {
    currTime := time.Now().In(boil.GetLocation())

    if o.CreatedAt.IsZero() {
        o.CreatedAt = currTime
    }
    if o.UpdatedAt.IsZero() {
        o.UpdatedAt = currTime
    }
}

// Updateの内部処理
if !boil.TimestampsAreSkipped(ctx) {
    currTime := time.Now().In(boil.GetLocation())

    o.UpdatedAt = currTime
}
```

## 4. Loadしたモデルを取ってくるときは、GetXXXを使う
- Loadを使っていない時、Rがnilになるので、ぬるぽを防げます
```go
    comment, _ := model.Comments(
        qm.Load(model.CommentRels.Users),
    ).One(ctx, a.conn)
	
    comment.R.GetUser()
```

```go
// Rの内部実装
func (r *commentR) GetUser() *User {
    if r == nil {
        return nil
    }
    return r.User
}
```

## 5. 外部キーで紐づくテーブルデータを芋蔓式に取りたい時の書き方
```
comments <-> users <-> teams
```

外部キーで紐づくテーブルをLoadする時は、ベースのテーブルを基準に、取ってくるテーブルごとにLoad処理を書く必要があります。
その際、qm.Relsを使うと、型安全でデータを取ってくることができます。
また、qm.Loadの第2引数以降には、Eager Loadingする時の条件を書くことができます。

```go
    comment, _ := model.Comments(
        qm.Load(model.CommentRels.Users), // コメントに紐づくユーザを取得
        qm.Load(qm.Rels(model.CommentRels.Users,model.UserResl.Teams),model.TeamWhere.Name.NEQ("hoge")), // コメントをベースにユーザに紐づくチームを取得 
    ).One(ctx, a.conn)

    user := comment.R.GetUser()
    team := user.R.GetTeam()
```

## 6. クエリでORを利用する時は、Or2とExprを併用する
OR2は、ORの適応範囲を明確にするために、Exprで囲んで、影響範囲を絞ることができます

```go
qms := []qm.QueryMod{
    qm.Expr(
        model.UserWhere.ID.NEQ(1),
        qm.Or2(model.UserWhere.Name.EQ("taro")),
    ),
}

// (user.id <> 1 or user.name = 'taro') 
```

## 7. テンプレートを使って独自のメソッドを追加する
- テンプレート機能を使うことで、各モデルに独自の処理を追加できます。
- 以下の例では、BulkInsertを追加しています。
```[gotemplate]
{{- $alias := .Aliases.Table .Table.Name -}}
{{- $schemaTable := .Table.Name | .SchemaTable}}

// InsertAll inserts all rows with the specified column values, using an executor.
func (o {{$alias.UpSingular}}Slice) InsertAll({{if .NoContext}}exec boil.Executor{{else}}ctx context.Context, exec boil.ContextExecutor{{end}}, columns boil.Columns) error {
    ln := int64(len(o))
    if ln == 0 {
        return nil
    }
    var sql string
    vals := []interface{}{}
    for i, row := range o {
        {{- template "timestamp_bulk_insert_helper" . }}

        {{if not .NoHooks -}}
        if err := row.doBeforeInsertHooks(ctx, exec); err != nil {
            return  errors.Wrap(err, "before insert hooks failed")
        }
        {{- end}}

        nzDefaults := queries.NonZeroDefaultSet({{$alias.DownSingular}}ColumnsWithDefault, row)
        wl, _ := columns.InsertColumnSet(
            {{$alias.DownSingular}}AllColumns,
            {{$alias.DownSingular}}ColumnsWithDefault,
            {{$alias.DownSingular}}ColumnsWithoutDefault,
            nzDefaults,
        )
        if i == 0 {
            sql = "INSERT INTO {{$schemaTable}} " + "({{.LQ}}" + strings.Join(wl, "{{.RQ}},{{.LQ}}") + "{{.RQ}})" + " VALUES "
        }
        sql += strmangle.Placeholders(dialect.UseIndexPlaceholders, len(wl), len(vals)+1, len(wl))
        if i != len(o)-1 {
            sql += ","
        }
        valMapping, err := queries.BindMapping({{$alias.DownSingular}}Type, {{$alias.DownSingular}}Mapping, wl)
        if err != nil {
            return errors.Wrap(err,"bind mapping failed")
        }
        value := reflect.Indirect(reflect.ValueOf(row))
        vals = append(vals, queries.ValuesFromMapping(value, valMapping)...)
    }
    if boil.DebugMode {
        fmt.Fprintln(boil.DebugWriter, sql)
        fmt.Fprintln(boil.DebugWriter, vals...)
    }

    {{if .NoContext -}}
    _, err := exec.Exec(ctx, sql, vals...)
    {{else -}}
    _, err := exec.ExecContext(ctx, sql, vals...)
    {{end -}}

    if err != nil {
        return errors.Wrap(err, "{{.PkgName}}: unable to insert into {{.Table.Name}}")
    }

    return nil
}

{{- define "timestamp_bulk_insert_helper" -}}
    {{- if not .NoAutoTimestamps -}}
    {{- $colNames := .Table.Columns | columnNames -}}
    {{if containsAny $colNames "created_at" "updated_at"}}
        {{if not .NoContext -}}
    if !boil.TimestampsAreSkipped(ctx) {
        {{end -}}
        currTime := time.Now().In(boil.GetLocation())
        {{range $ind, $col := .Table.Columns}}
            {{- if eq $col.Name "created_at" -}}
                {{- if eq $col.Type "time.Time" }}
        if row.CreatedAt.IsZero() {
            row.CreatedAt = currTime
        }
                {{- else}}
        if queries.MustTime(row.CreatedAt).IsZero() {
            queries.SetScanner(&row.CreatedAt, currTime)
        }
                {{- end -}}
            {{- end -}}
            {{- if eq $col.Name "updated_at" -}}
                {{- if eq $col.Type "time.Time"}}
        if row.UpdatedAt.IsZero() {
            row.UpdatedAt = currTime
        }
                {{- else}}
        if queries.MustTime(row.UpdatedAt).IsZero() {
            queries.SetScanner(&row.UpdatedAt, currTime)
        }
                {{- end -}}
            {{- end -}}
        {{end}}
        {{if not .NoContext -}}
    }
        {{end -}}
    {{end}}
    {{- end}}
{{- end -}}

```

コードを生成すると、モデルごとに`InsertAll`が生成されます。
```go

// InsertAll inserts all rows with the specified column values, using an executor.
func (o UserSlice) InsertAll(ctx context.Context, exec boil.ContextExecutor, columns boil.Columns) error {
	ln := int64(len(o))
	if ln == 0 {
		return nil
	}
	var sql string
	vals := []interface{}{}
	for i, row := range o {

		if err := row.doBeforeInsertHooks(ctx, exec); err != nil {
			return errors.Wrap(err, "before insert hooks failed")
		}

		nzDefaults := queries.NonZeroDefaultSet(UserColumnsWithDefault, row)
		wl, _ := columns.InsertColumnSet(
			UserAllColumns,
			UserColumnsWithDefault,
			UserColumnsWithoutDefault,
			nzDefaults,
		)
		if i == 0 {
			sql = "INSERT INTO `sleep_learning_quiz_content` " + "(`" + strings.Join(wl, "`,`") + "`)" + " VALUES "
		}
		sql += strmangle.Placeholders(dialect.UseIndexPlaceholders, len(wl), len(vals)+1, len(wl))
		if i != len(o)-1 {
			sql += ","
		}
		valMapping, err := queries.BindMapping(UserType, UserMapping, wl)
		if err != nil {
			return errors.Wrap(err, "bind mapping failed")
		}
		value := reflect.Indirect(reflect.ValueOf(row))
		vals = append(vals, queries.ValuesFromMapping(value, valMapping)...)
	}
	if boil.DebugMode {
		fmt.Fprintln(boil.DebugWriter, sql)
		fmt.Fprintln(boil.DebugWriter, vals...)
	}

	_, err := exec.ExecContext(ctx, sql, vals...)
	if err != nil {
		return errors.Wrap(err, "model: unable to insert into sleep_learning_quiz_content")
	}

	return nil
}

```

### ちなみに
このテンプレート機能を使って、便利なメソッドを追加されているリポジトリがあるので、ぜひ参考にしてください。
https://github.com/tiendc/sqlboiler-extensions

## 8. デバッグするために、実行されるSQLを確認する
- 実行されたクエリを確認できます
```go
db, err := sql.Open("mysql", source)
if err != nil {
    return nil, err
}

boil.SetDB(db)
boil.DebugMode = true
// 出力先の変更
fh, _ := os.Open("log.txt")
boil.DebugWriter = fh
```

## 9. 特定のモデルに紐づくモデルを取得する
- Userに紐づくTeamを取得する場合は、以下のようにかけます
```go
user := &model.User{ID: 1}
teams ,err := user.Teams().All(ctx, db)
```

## 10. 特定のモデルに対して、後からデータを紐づける
- 以下のように、モデルのRに対して、後からデータを紐づけることができます。
- スライス/単数のモデルどちらでも対応できるようになっています。
```go
users := []*model.User{
    &model.User{ID: 1},
    &model.User{ID: 2},
}
// 引数に関して
// singular=trueにすると、単数モデルに対して紐づける
// singular=falseにすると、複数のモデルに対して紐づける
_ = (&model.User{}).L.LoadTeams(ctx, db, false, &ms, nil)

for _ ,v := range users {
    user := v
    fmt.Printf("team = %+v\n", user.R.GetTeam())
}
```

## 11 モデルに対してデータを追加する
- モデルに対して紐づくモデルのデータを追加・更新時は、以下のようにかけます
```go

team := &model.Team{
    ID: 1,
    Name: "taro",
}

// 複数追加
// true=insert, false=update
team.AddUser(ctx, db, true, &model.User{
    ID: 1,
	Name: "taro",
})

// 単数
// true=insert, false=update
user.SetTeam(ctx, db, true, &model.Team{
    Name: "team",
})

```

## 12. モデルをReloadする
- モデルを再更新する時は、以下のようにかけます
```go
user := &model.User{ID: 1}
_ = user.Reload(ctx, db)
```

## 13. Hookを使って、共通処理を書く
- 処理の前後に共通の処理を書くことができます。
```go
const (
  BeforeInsertHook HookPoint = iota + 1
  BeforeUpdateHook
  BeforeDeleteHook
  BeforeUpsertHook
  AfterInsertHook
  AfterSelectHook
  AfterUpdateHook
  AfterDeleteHook
  AfterUpsertHook
)
```
```go
func beforeInsertHook(ctx context.Context, exec boil.ContextExecutor, u *User) error {
  if u.Name == "" {
    return errors.New("name is empty")
  }
  return nil
}

models.AddUserHook(boil.BeforeInsertHook, beforeInsertHook)
```

## 14. 生成する命名を個別変更する
`sqlboiler.toml` に`aliases.tables`を設定することで、生成されるモデル名を変更することができます。

```toml
[[aliases.tables]]
name          = "user_poms"
up_plural     = "UserPomses"
up_singular   = "UserPoms"
down_plural   = "userPomses"
down_singular = "userPoms"
```


## 15. Joinを簡単にかけるような関数を作成する
Joinを関数化しておくことで、生成されたコードに含まれるテーブルとカラムの変数を使って、Joinを書くことができます。

```go
func InnerJoin(joinTable, baseTable, joinTableColumn, baseTableColumn string) qm.QueryMod {
	return qm.InnerJoin(fmt.Sprintf("%s ON %s.%s = %s.%s",
		joinTable,
		joinTable,
		joinTableColumn,
		baseTable,
		baseTableColumn,
	))
}

func LeftOuterJoin(joinTable, baseTable, joinTableColumn, baseTableColumn string) qm.QueryMod {
	return qm.LeftOuterJoin(fmt.Sprintf("%s ON %s.%s = %s.%s",
		joinTable,
		joinTable,
		joinTableColumn,
		baseTable,
		baseTableColumn,
	))
}

```

### 使い方
```go
users, err := model.Users(
    InnerJoin(model.TableNames.Team, model.TableNames.User, model.TeamColumns.ID, model.UserColumns.TeamID), 
    model.TeamWhere.ID.EQ(1),
).All(ctx, db)
```

## 16. IN句を簡単にかけるような関数を作成する
- IN句を使う時、スライスをそのまま渡すことができないため、スライスを渡すための関数を作成することで、簡単にIN句を使うことができます。


```go
type ArrayInt64 []int64

func (ai ArrayInt64) IN() []interface{} {
	values := make([]interface{}, 0, len(ai))
	for _, value := range ai {
		values = append(values, value)
	}
	return values
}

func (ai ArrayInt64) INString() string {
	s := make([]string, len(ai))
	for i, v := range ai {
		s[i] = strconv.Itoa(int(v))
	}
	return strings.Join(s, ",")
}
```

### 使い方
```go
func GetUsersByUserIDs(ctx context.Context, db *sql.DB, userIDs []int64{}) ([]*model.User, error) {
    users, err := model.Users(
	    qm.WhereIn("id IN ?", ArrayInt64(userIDs).IN()...),
    ).All(ctx, db)
}

func GetUsersByUserIDs(ctx context.Context, db *sql.DB, userIDs []int64{}) ([]*model.User, error) {
    users, err := model.Users(
	    qm.Where(fmt.Sprintf("id IN (%s)", ArrayInt64(userIDs).INString())),
    ).All(ctx, db)
}

```

## 17. Eager Loadingを共通化する
取得時、Eager Loadingを共通化することで、コードの重複を減らすことができます。
また、Loadの抜け漏れがなくなるため、安全にデータを取ってくることができます。

```go
    func loadComment((s ...qm.QueryMod) []qm.QueryMod {
        return append(s, []qm.QueryMod{
            qm.Load(qm.Rels(
                model.CommentRels.Users,
                model.UsersRels.Teams,
            )),
            qm.Load(model.CommentRels.Images),
        }...)
    }
```

### 使い方
```go
    comment, err := model.Comments(
		loadComment(
			model.CommentWhere.ID.EQ(1),
		)...,
	).One(ctx, a.conn)

    // 以下のように、Loadしたオブジェクトを取ってくることができます
    user := comment.R.GetUser()
    user.R.GetTeam()
```



## ハマりポイント1: 値がゼロ値の時にデフォルト値が優先されてしまう
以下のようなカラムに対して、
```go
`is_test` tinyint(1) NOT NULL DEFAULT 1 -- is_test=0は値が1として更新
`is_test_two` tinyint(1) NOT NULL -- 問題なし
```

`is_test`は、値がfalseの時に、デフォルト値が設定されます。
```go
user.IsTest = false
user.IsTestTwo = false

_ = user.Insert(ctx, db, boil.Infer()) 

// output
// user.IsTest => true
// user.IsTestTwo => false
```

これは、`boil.Iner()`の仕様として、「非ゼロのデフォルト値を持つカラム+デフォルト値がないカラム」が選択されることが原因です。
IsTestは、ゼロ値かつデフォルト値があるカラムなので、insert文には含まれず、デフォルト値がレコードに入ります。
上記ゼロ値でもデータを更新できるようにしたい場合は、WhiteListやGrayListを使って、明示的にカラムを指定する必要があります。

## ハマりポイント.2: Bindで同じカラム名があるとうまく取得できない。

```go
type userDetail struct {
    User *User `boil:",bind"`
    Team *Team `boil:",bind"`
}
var u userDetail
model.Users(
    qm.Select("user.*, team.*"), 
    InnerJoin(model.TableNames.Team, model.TableNames.User, model.TeamColumns.ID, model.UserColumns.TeamID),
).BindG(context.Background(), &u)
fmt.Printf("userDetail = %+v\n", u)
```

- bind機能で、Selectで指定したカラムをモデルによしなにバインドできます。しかし、上記のように、User/Teamそれぞれに、同じカラム(ex `ID int64`)がある場合、うまくそれぞれのIDを取得できません。
https://github.com/volatiletech/sqlboiler/issues/664


## ハマりポイント.3: 複合キーを使う時のUpsert
複合主キーでのテーブルでは、DBの種類によっての挙動の違いにより、Upsertは意図しない挙動になることがあります。
複合主キーの場合は`Exists()`で存在の有無を確認してから、`Insert()`/`Update()`を使うことをおすすめします。

https://github.com/volatiletech/sqlboiler/issues/328

