-- Connect the trade-only adapter to the same native trade APIs as Utility Blue Hub.
return function(context, env, config, factories)
    local player, modules = context.player, context.modules
    local Players, RS = game:GetService("Players"), game:GetService("ReplicatedStorage")
    local CD, DB, UIManager = modules.ClientData, modules.InventoryDB, modules.UIManager
    local resolver = factories.makeNameResolver(DB)
    local preparation = factories.makeTradePreparation({CD=CD, Router=modules.RouterClient,
        spawn=task.spawn, EquipPermissions=modules.EquipPermissions})
    local function conflict()
        local old=env.UtilityBlueHub
        local state=type(old)=="table" and old.Engine and old.Engine.State
        if type(state)=="table" and (state.enabled or state.pending) then
            return "Utility Blue Hub lama masih berjalan. Hentikan prosesnya sebelum trade-only."
        end
        local aax=env.AAXKaitun
        if type(aax)=="table" and aax.Running then
            if aax.Stopping or aax.EventReservation or aax.ActiveThread or aax.EventCleanupThread then
                return "Menunggu pekerjaan script lain selesai."
            end
            if aax.Config and aax.Config.AutoRecycle and aax.Config.AutoRecycle.Enabled then
                return "Proses inventory script lain masih aktif."
            end
        end
    end
    local warnings=factories.makeTradeWarnings({context=workspace,clock=os.clock,
        getTranslator=function()
            return game:GetService("LocalizationService"):GetTranslatorForPlayer(player)
        end})
    local adapter=factories.makeTradeAdapter({CD=CD,DB=DB,Locks=modules.BackpackLockTracker,
        ItemHider=modules.ItemHider,License=modules.TradeLicenseHelper,Policy=modules.PolicyHelper,
        Constants=modules.SharedConstants,Router=modules.RouterClient,RS=RS,player=player,
        Players=Players,game=game,spawn=task.spawn,wait=task.wait,clock=os.clock,
        resolver=resolver,conflict=conflict,
        unequipTradePet=preparation.unequipTradePet,removeTradePetFromPen=preparation.removeTradePetFromPen,
        isAccessoryEquipped=function(item)
            assert(type(item)=="table" and type(item.unique)=="string","Accessory identity is unavailable.")
            local worn,equipment=CD.get("pet_saved_worn_items"),CD.get("equip_manager")
            assert(type(worn)=="table" and type(equipment)=="table","Accessory assignment data is not ready.")
            local lists,held=worn.wearing_lists or {},equipment.pet_accessories or {}
            assert(type(lists)=="table" and type(held)=="table","Invalid accessory assignment data.")
            local assigned=false
            for _,groups in pairs(lists) do
                assert(type(groups)=="table","Invalid pet accessory groups.")
                for _,group in pairs(groups) do
                    assert(type(group)=="table","Invalid pet accessory list.")
                    for _,unique in pairs(group) do
                        assert(type(unique)=="string" and unique~="","Invalid worn accessory identity.")
                        if unique==item.unique then assigned=true end
                    end
                end
            end
            for _,equipped in pairs(held) do
                assert(type(equipped)=="table" and type(equipped.unique)=="string" and equipped.unique~="",
                    "Invalid held accessory identity.")
                if equipped.unique==item.unique then assigned=true end
            end
            return assigned
        end,
        handleTradeWarning=function(expected,authorize)
            if not expected or type(authorize)~="function" or not authorize() then return "blocked" end
            local function matches()
                if not authorize() then return false end
                local ui=UIManager.apps and UIManager.apps.TradeApp
                if not ui or type(ui._get_local_trade_state)~="function" then return false end
                local current=ui:_get_local_trade_state()
                return type(current)=="table" and current.trade_id==expected.tradeId
                    and current.current_stage=="confirmation" and authorize()
            end
            if not matches() then return "blocked" end
            local rules,translationState,canRetry=warnings.GetRules(matches,expected.tradeId)
            if not matches() then return "blocked","trade_changed_during_translation" end
            if not rules then return translationState=="pending" and "pending" or "blocked","trade_warning_translation_unavailable" end
            local status,reason=context.nativeUI.HandleNormal(rules,matches)
            if not matches() then return "blocked","trade_changed_during_warning" end
            if status=="blocked" and reason=="unknown_dialog_text" and canRetry then
                local refreshed,nextState,retryAvailable=warnings.GetRules(matches,expected.tradeId,true)
                if not matches() then return "blocked","trade_changed_during_translation" end
                if refreshed and refreshed~=rules then
                    status,reason=context.nativeUI.HandleNormal(refreshed,matches)
                    if not matches() then return "blocked","trade_changed_during_warning" end
                end
                if status=="blocked" and reason=="unknown_dialog_text" and (retryAvailable or nextState=="pending")then
                    return "pending","trade_warning_translation_pending"
                end
            end
            if status~="none" then return status,reason end
            if not matches() then return "blocked" end
            local dialog=UIManager.apps and UIManager.apps.DialogApp
            local total,completed=dialog and dialog.ticket_count,dialog and dialog.completed_ticket
            local function counter(value)
                return type(value)=="number" and value==value and value<math.huge and value>=0 and value%1==0
            end
            if not counter(total) or not counter(completed) or completed>total then return "pending" end
            return total==completed and "none" or "pending"
        end,
        getTradeTiming=function()
            local ui=UIManager.apps and UIManager.apps.TradeApp
            if not ui or type(ui._get_local_trade_state)~="function" or not ui.lock_countdown then return end
            local current=ui:_get_local_trade_state()
            if type(current)~="table" then return end
            return {tradeId=current.trade_id,stage=current.current_stage,offerVersion=current.offer_version,
                going=ui.lock_countdown:is_going(),remaining=math.max(0,ui.lock_countdown:get_remaining_time())}
        end},config)
    return adapter,conflict
end
