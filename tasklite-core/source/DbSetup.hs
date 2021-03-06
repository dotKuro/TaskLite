{-# OPTIONS_GHC -fno-warn-incomplete-record-updates #-}

{-|
Creates all tables and views
-}

module DbSetup where

import Protolude as P

import Data.Text as T
import Database.SQLite.Simple as Sql
import qualified SqlUtils as S
import Task
import Language.SQL.SimpleSQL.Syntax
import Language.SQL.SimpleSQL.Pretty
import Data.Text.Prettyprint.Doc hiding ((<>))
import Config


createTaskTable :: Config -> Connection -> IO (Doc ann)
createTaskTable conf connection = do
  let
    theTableName = tableName conf
    -- TODO: Replace with beam-migrate based table creation
    createTableQuery = S.getTable theTableName (
      "`ulid` text not null primary key" :
      "`body` text not null" :
      ("`state` text check(`state` in (" <> stateOptions
        <> ")) not null default '" <> show stateDefault <> "'") :
      "`due_utc` text" :
      "`closed_utc` text" :
      "`modified_utc` text not null" :
      "`priority_adjustment` float" :
      "`metadata` text" :
      [])

  S.createTableWithQuery
    connection
    theTableName
    createTableQuery


createTriggerModified :: Connection -> IO (Doc ann)
createTriggerModified connection =
  -- Update modified_utc whenever a task is updated
  -- (and modified_utc itself isn't changed)
  S.createWithQuery connection $
    S.createTriggerAfterUpdate "set_modified_utc" "tasks"
      "`new`.`modified_utc` is `old`.`modified_utc`"
      "\
        \update `tasks`\n\
        \set `modified_utc` = datetime('now')\n\
        \where `ulid` = `new`.`ulid`\n\
        \"


createTriggerClosed :: Connection -> IO (Doc ann)
createTriggerClosed connection =
  S.createWithQuery connection $
    S.createTriggerAfterUpdate "set_closed_utc" "tasks"
      "old.state is not new.state and (\n\
        \new.state is 'Done'\n\
        \or new.state is 'Obsolete'\n\
        \or new.state is 'Deletable'\n\
        \)"
      "\
        \update tasks\n\
        \set closed_utc = datetime('now')\n\
        \where ulid = new.ulid\n\
        \"


taskViewQuery :: Config -> Query
taskViewQuery conf =
  let
    caseAwakeSql = S.getCase Nothing (
      ("`awake_utc` is null",                        0) :
      ("`awake_utc` >= datetime('now')",            -5) :
      ("`awake_utc` >= datetime('now', '-1 days')",  1) :
      ("`awake_utc` >= datetime('now', '-2 days')",  2) :
      ("`awake_utc` >= datetime('now', '-5 days')",  5) :
      ("`awake_utc` <  datetime('now', '-5 days')",  9) :
      [])

    caseWaitingSql = S.getCase Nothing (
      ("waiting_utc is null",              0) :
      ("waiting_utc >= datetime('now')",   0) :
      ("waiting_utc <  datetime('now')", -10) :
      [])

    caseReviewSql = S.getCase Nothing (
      ("review_utc is null",             0) :
      ("review_utc >= datetime('now')",  0) :
      ("review_utc <  datetime('now')", 20) :
      [])

    caseDueSql = S.getCase Nothing (
      ("due_utc is null",                           0) :
      ("`due_utc` >= datetime('now', '+24 days')",  0) :
      ("`due_utc` >= datetime('now',  '+6 days')",  3) :
      ("`due_utc` >= datetime('now')",              6) :
      ("`due_utc` >= datetime('now',  '-6 days')",  9) :
      ("`due_utc` >= datetime('now', '-24 days')", 12) :
      ("`due_utc` <  datetime('now', '-24 days')", 15) :
      [])

    caseStateSql = S.getCase Nothing (
      ("state is null",          0) :
      ("state == 'Done'",        0) :
      ("state == 'Obsolete'",   -1) :
      ("state == 'Deletable'", -10) :
      [])

    selectQuery = S.getSelect
      (
        "`tasks`.`ulid` as `ulid`" :
        "`tasks`.`body` as `body`" :
        "`tasks`.`modified_utc`as `modified_utc`" :
        "`tasks`.`awake_utc` as `awake_utc`" :
        "`tasks`.`ready_utc` as `ready_utc`" :
        "`tasks`.`waiting_utc` as `waiting_utc`" :
        "`tasks`.`review_utc` as `review_utc`" :
        "`tasks`.`due_utc` as `due_utc`" :
        "`tasks`.`closed_utc` as `closed_utc`" :
        "`tasks`.`state` as `state`" :
        "`tasks`.`group_ulid` as `group_ulid`" :
        "`tasks`.`repetition_duration` as `repetition_duration`" :
        "`tasks`.`recurrence_duration` as `recurrence_duration`" :
        "group_concat(distinct `task_to_tag`.`tag`) as `tags`" :
        "group_concat(distinct `task_to_note`.`note`) as `notes`" :
        "ifnull(`tasks`.`priority_adjustment`, 0.0)\n\
        \  + " <> caseAwakeSql <> "\n\
        \  + " <> caseWaitingSql <> "\n\
        \  + " <> caseReviewSql <> "\n\
        \  + " <> caseDueSql <> "\n\
        \  + " <> caseStateSql <> "\n\
        \  + case count(`task_to_note`.`note`)\n\
        \      when 0 then 0.0\n\
        \      else 1.0\n\
        \    end\n\
        \  + case count(`task_to_tag`.`tag`)\n\
        \      when 0 then 0.0\n\
        \      else 2.0\n\
        \    end\n\
        \as `priority`" :
        "`tasks`.`user`as `user`" :
        "`tasks`.`metadata`as `metadata`" :
        []
      )
      (
        "`" <> tableName conf <> "` \n\
        \left join task_to_tag on tasks.ulid = task_to_tag.task_ulid \n\
        \left join task_to_note on tasks.ulid = task_to_note.task_ulid \n\
        \"
      )
      "`tasks`.`ulid`"
  in
    selectQuery


createTaskView :: Config -> Connection -> IO (Doc ann)
createTaskView conf connection = do
  let
    viewName = "tasks_view"

  S.createTableWithQuery
    connection
    viewName
    (S.getView viewName $ taskViewQuery conf)


replaceTaskView :: Config -> Connection -> IO (Doc ann)
replaceTaskView conf connection = do
  let
    viewName = "tasks_view"

  execute_ connection $ Query $ "drop view if exists `" <> viewName <> "`"

  S.createTableWithQuery
    connection
    viewName
    (S.getView viewName $ taskViewQuery conf)


createTagsTable :: Config ->  Connection -> IO (Doc ann)
createTagsTable conf connection = do
  let
    theTableName = "task_to_tag"
    createTableQuery = S.getTable theTableName (
      "`ulid` text not null primary key" :
      "`task_ulid` text not null" :
      "`tag` text not null" :
      "foreign key(`task_ulid`) references `" <> tableName conf <> "`(`ulid`)" :
      "constraint `no_duplicate_tags` unique (`task_ulid`, `tag`) " :
      [])

  S.createTableWithQuery
    connection
    theTableName
    createTableQuery


tagsViewQuery :: Query
tagsViewQuery =
  let
    txtToName = (Name Nothing) . T.unpack

    tasks_t         = txtToName "tasks"
    task_to_tag_t   = txtToName "task_to_tag"
    task_to_tag_1_t = txtToName "task_to_tag_1"
    task_to_tag_2_t = txtToName "task_to_tag_2"

    closed_count_c  = txtToName "closed_count"
    tag_c           = txtToName "tag"
    ulid_c          = txtToName "ulid"
    task_ulid_c     = txtToName "task_ulid"
    closed_utc_c    = txtToName "closed_utc"
    open_c          = txtToName "open"
    closed_c        = txtToName "closed"
    progress_c      = txtToName "progress"

    t1Tag = S.tableCol task_to_tag_1_t tag_c
    t2Tag = S.tableCol task_to_tag_2_t tag_c
    t1TagCount = S.count t1Tag
    closedCount = S.ifNull closed_count_c "0"
    openCount = Parens $ t1TagCount `S.sub` closedCount

    subQueryAst = makeSelect
      { qeSelectList = (
          S.col tag_c `S.as` (Name Nothing "") :
          S.count (S.tableCol tasks_t ulid_c) `S.as` closed_count_c :
          [])
      , qeFrom = [ S.leftJoinOn tasks_t task_to_tag_t $
            (tasks_t `S.dot` ulid_c)
            `S.is`
            (task_to_tag_t `S.dot` task_ulid_c)
          ]
      , qeWhere = Just $ S.isNotNull closed_utc_c
      , qeGroupBy = [ S.groupBy $ S.col tag_c ]
      }
    selectQueryAst = makeSelect
      { qeSelectList = (
          t1Tag `S.as` (Name Nothing "") :
          openCount `S.as` open_c :
          closedCount `S.as` closed_c :
          (S.roundTo 6 (closedCount `S.castTo` "float" `S.div` t1TagCount))
            `S.as` progress_c :
          [])
      , qeFrom = [ S.leftTRJoinOn
          (TRAlias
            (TRSimple [task_to_tag_t])
            (S.alias task_to_tag_1_t))
          (TRAlias
            (TRQueryExpr subQueryAst)
            (S.alias task_to_tag_2_t))
          (t1Tag `S.is` t2Tag)
        ]
      , qeGroupBy = [ S.groupBy t1Tag ]
      , qeOrderBy = [ S.orderByAsc t1Tag ]
      }
    selectQueryText = T.pack $ prettyQueryExpr ansi2011 selectQueryAst
  in
    Query selectQueryText


createTagsView :: Connection -> IO (Doc ann)
createTagsView connection = do
  let viewName = "tags"

  S.createTableWithQuery
    connection
    viewName
    (S.getView viewName tagsViewQuery)


replaceTagsView :: Connection -> IO (Doc ann)
replaceTagsView connection = do
  let viewName = "tags"

  execute_ connection $ Query $ "drop view if exists `" <> viewName <> "`"

  S.replaceTableWithQuery
    connection
    viewName
    (S.getView viewName tagsViewQuery)


createNotesTable :: Config -> Connection -> IO (Doc ann)
createNotesTable conf connection = do
  let
    theTableName = "task_to_note"
    createTableQuery = S.getTable theTableName (
      "`ulid` text not null primary key" :
      "`task_ulid` text not null" :
      "`note` text not null" :
      "foreign key(`task_ulid`) references `" <> tableName conf <> "`(`ulid`)" :
      [])

  S.createTableWithQuery
    connection
    theTableName
    createTableQuery


createViewsAndTriggers :: Config -> Connection -> IO (Doc ann)
createViewsAndTriggers conf connection = do
  tr1 <- createTriggerModified connection
  tr2 <- createTriggerClosed connection

  v1 <- createTaskView conf connection
  v2 <- createTagsView connection

  pure $ tr1 <> tr2 <> v1 <> v2


replaceViewsAndTriggers :: Config -> Connection -> IO (Doc ann)
replaceViewsAndTriggers conf connection = do
  execute_ connection "drop trigger if exists `set_modified_utc_after_update`"
  tr1 <- createTriggerModified connection

  execute_ connection "drop trigger if exists `set_closed_utc_after_update`"
  tr2 <- createTriggerClosed connection

  v1 <- replaceTaskView conf connection
  v2 <- replaceTagsView connection

  pure $ tr1 <> tr2 <> v1 <> v2


createTables :: Config -> Connection -> IO (Doc ann)
createTables conf connection = do
  t1 <- createTaskTable conf connection
  t2 <- createTagsTable conf connection
  t3 <- createNotesTable conf connection

  viewsTriggers <- createViewsAndTriggers conf connection

  pure $ t1 <> t2 <> t3 <> viewsTriggers
