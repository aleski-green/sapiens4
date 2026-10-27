{-# LANGUAGE OverloadedStrings #-}
module Sapiens.Groups (module Sapiens.GroupModel, groupControl) where

import Sapiens.Types
import Sapiens.GroupModel
import qualified Sapiens.GroupChat as Chat
import qualified Sapiens.GroupWork as Work

groupControl s actor input = do
 let op = at input "op"; payload = remove ["op","group"] input; gid = at input "group"
 case op of
  "group_create" -> createGroup s payload actor
  "group_update" -> updateGroup s gid payload actor
  _ -> do
   group <- getGroup s gid (op /= "group_get")
   authorizeGroup s group actor Member
   case op of
    "group_get" -> pure group
    "group_message" -> Chat.submitGroup s gid payload actor
    "group_task_create" -> Work.createTask s gid payload actor
    "group_task_update" -> Work.updateTask s gid (at payload "task") (remove ["task"] payload) actor
    "group_task_run" -> do
     root <- Chat.activeRoot s gid actor
     result <- Work.startTask s gid (at payload "task") (get payload "revision") actor root
     Chat.dispatchGroups s
     pure result
    _ -> failure 400 "Unknown Group operation"
