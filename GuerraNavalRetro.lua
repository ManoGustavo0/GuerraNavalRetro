-- Guerra Naval Hub | RetroBox API 2 (stable) | 113987393426315
local function main()
if type(setthreadidentity)=='function' then setthreadidentity(8) end
local LOADER_URL = 'https://raw.githubusercontent.com/ManoGustavo0/RetroBox/main/dist/bootstrap/v2.lua'
local Players = game:GetService('Players')
local RS = game:GetService('ReplicatedStorage')
local player = Players.LocalPlayer
local env = getgenv()
if game.PlaceId ~= 113987393426315 then warn('Este script é para Guerra Naval.'); return end

local ok,Library = pcall(function()
    local chunk,err=loadstring(game:HttpGet(LOADER_URL), '@RetroBox-bootstrap-v2')
    if not chunk then error(err) end
    return chunk({Channel='stable'})
end)
if not ok or type(Library)~='table' or Library.APIVersion~=2 or type(Library.CreateWindow)~='function' then
    warn('Falha ao carregar RetroBox API 2: '..tostring(Library)); return
end
local modulesOk,dependencies=pcall(function()
    return {
        data=require(RS.client.modules.ClientData),
        bridge=require(RS.util.GetBridge),
        plot=require(RS.util.GetPlotModel),
        resources=require(RS.shared.config.ResourcesConfig),
        buildings=require(RS.shared.config.BuildingsConfig),
        quests=require(RS.shared.config.QuestsConfig),
        daily=require(RS.shared.config.DailyRewardsConfig),
    }
end)
if not modulesOk then warn('Falha nos módulos do jogo: '..tostring(dependencies)); return end
local D=dependencies
local deadline=os.clock()+15
repeat task.wait(.1) until D.data.playerProducer or os.clock()>=deadline
if not D.data.playerProducer then warn('Dados do jogador ainda não carregados.'); return end
if env.GuerraNavalRetro and env.GuerraNavalRetro.Destroy then env.GuerraNavalRetro:Destroy() end

local categoryNames={'Fábricas e minas','Depósitos','Transportes','Cristais','Clonagem'}
local state={collect=false,sell=false,rewards=false,builders=false,mode='Acumular materiais',interval=2,sellInterval=10,minimum=1,categories=table.clone(categoryNames)}
local hub={alive=true,epoch=0,state=state,status='Pronto',collected=0,units=0,sales=0,earned=0,rewardCount=0,assigned=0,requests=0,errors=0}
env.GuerraNavalRetro=hub
local controls={}
local window=Library:CreateWindow({
    Id='GuerraNaval-'..game.PlaceId,Title='Guerra Naval Hub',Subtitle='Guerra Naval Hub · economia e materiais',
    Icon='globe',Theme='Retro98',Locale='pt-BR',Settings=true,ShowProfile=true,Launcher=true,
    Parent=player:WaitForChild('PlayerGui'),
    ToggleKey=Enum.KeyCode.RightShift,DestroyOnClose=false,PixelIcons=true,PixelDecorations=true,
    ConfigFolder='RetroBox/GuerraNaval/'..game.PlaceId,
    CallbackExecutor=function(callback,args)
        if type(setthreadidentity)=='function' then setthreadidentity(8) end
        return callback(table.unpack(args,1,args.n))
    end,
})
hub.window=window
local tasks={}
local activeActions={}
local saleState=window:CreateState('Desligada',{Name='Venda periódica'})
local cachedBridges={}
local cachedModels={}
local cacheAt=0
local cooldown={}
local resourceAttributes={}
for name in pairs(D.resources) do resourceAttributes[name]=true end
for name,config in pairs(D.buildings) do
    if type(config)=='table' and (config.GrownResource or config.Type=='CloneFacility') then
        resourceAttributes[name]=true; resourceAttributes[name:gsub(' ','')]=true
        if config.magnetAttributeName then resourceAttributes[config.magnetAttributeName]=true end
    end
end
local function profile() return D.data.playerProducer:getState().player end
local function cash(p) return tonumber((p or profile()).money) or 0 end
local function amount(p,name) return tonumber(p.backpack[name] and p.backpack[name].amount) or 0 end
local function categories()
    local result={}
    for _,name in ipairs(state.categories) do result[name]=true end
    return result
end
local function check(ctx)
    if ctx then ctx:ThrowIfCancelled() end
    if not hub.alive then error('Script encerrado') end
end
local function send(ctx,name,...)
    check(ctx)
    if not hub.alive then return false end
    if not cachedBridges[name] then cachedBridges[name]=D.bridge(name) end
    check(ctx)
    cachedBridges[name]:Fire(...)
    hub.requests+=1
    return true
end
local function waitUntil(ctx,predicate,seconds)
    local limit=os.clock()+seconds
    repeat
        check(ctx)
        if predicate() then return true end
        task.wait(.1)
    until os.clock()>=limit
    check(ctx)
    return hub.alive and predicate() or false
end
local function category(model)
    local cfg=D.buildings[model.Name]
    local kind=model:GetAttribute('type') or (cfg and cfg.Type)
    if kind=='Farm' then return 'Fábricas e minas' end
    if kind=='GemMine' then return 'Cristais' end
    if kind=='CloneFacility' then return 'Clonagem' end
    if kind=='Storage' or model.Name=='Vault' then return 'Depósitos' end
    if kind=='Transport' then return 'Transportes' end
end
local function models(force)
    if not force and os.clock()-cacheAt<5 then return cachedModels end
    cacheAt=os.clock(); cachedModels={}
    local plot=D.plot(player)
    if not plot then return cachedModels end
    local seen={}
    local function add(folder,requireOwnership)
        if not folder then return end
        local p=profile()
        for _,m in ipairs(folder:GetChildren()) do
            if m:IsA('Model') and not seen[m] and category(m) then
                local id=m:GetAttribute('id')
                if not requireOwnership or (id and p.plotBuildings[id]) then
                    seen[m]=true; table.insert(cachedModels,m)
                end
            end
        end
    end
    local root=plot:FindFirstChild('Plot')
    add(root and root:FindFirstChild('Buildings'))
    add(plot:FindFirstChild('Assets'))
    add(RS:FindFirstChild('HiddenPlotBuildings'),true)
    return cachedModels
end
local function ready(model)
    if not model.Parent or model:HasTag('UnfinishedBuilding') then return 0 end
    local qty=tonumber(model:GetAttribute('ResourcesToCollect')) or 0
    if qty>0 then return qty end
    if category(model)=='Depósitos' or category(model)=='Transportes' then
        for name,value in pairs(model:GetAttributes()) do
            if resourceAttributes[name] and type(value)=='number' and value>0 then qty+=value end
        end
    end
    return qty
end
local function totalMaterials(p)
    local total=0
    for name,item in pairs(p.backpack or {}) do
        if D.resources[name] then total+=tonumber(item.amount) or 0 end
    end
    return total
end
local function sellable(p)
    for name,item in pairs(p.backpack or {}) do
        if D.resources[name] and (tonumber(item.amount) or 0)>0 and not (p.LockedItems or {})[name] then return true end
    end
    return false
end
local function sellResources(ctx)
    check(ctx)
    local p=profile()
    if not sellable(p) then return true,'Nenhum recurso desbloqueado para vender' end
    local before=tonumber(p.overallEarnedMoney) or cash(p)
    local quantities={}
    for name,item in pairs(p.backpack) do
        if D.resources[name] and not (p.LockedItems or {})[name] then quantities[name]=tonumber(item.amount) or 0 end
    end
    hub.status='Vendendo recursos'
    send(ctx,'SellAll')
    local confirmed=waitUntil(ctx,function()
        local now=profile()
        for name,qty in pairs(quantities) do if amount(now,name)<qty then return true end end
        return false
    end,4)
    if not confirmed then return false,'Venda sem confirmação; nova tentativa após o intervalo' end
    task.wait(.15)
    check(ctx)
    local gain=math.max(0,(tonumber(profile().overallEarnedMoney) or cash())-before)
    hub.sales+=1; hub.earned+=gain
    return true,string.format('Venda confirmada · +%.0f dinheiro',gain)
end
local function collectAll(ctx,manual)
        check(ctx)
        local selected=categories()
        local confirmed,total=0,0
        local list=models(manual)
        for index,m in ipairs(list) do
            check(ctx)
            if not manual and not window:GetFlag('naval.collect.enabled') then break end
            local qty=ready(m)
            if selected[category(m)] and qty>=state.minimum and os.clock()>=(cooldown[m] or 0) then
                local before=totalMaterials(profile())
                local gems=tonumber(profile().gems) or 0
                hub.status='Coletando '..m.Name
                cooldown[m]=os.clock()+5
                send(ctx,'CollectResources',m)
                local accepted=waitUntil(ctx,function()
                    return (m.Parent and ready(m)<qty) or totalMaterials(profile())>before or (tonumber(profile().gems) or 0)>gems
                end,2.5)
                if accepted then
                    confirmed+=1; total+=qty; hub.collected+=1; hub.units+=qty
                end
                task.wait(.08)
                check(ctx)
            end
            if ctx and ctx.Action then ctx:SetProgress(index,#list,'Coletando '..index..' / '..#list) end
        end
        hub.status=window:GetFlag('naval.collect.enabled') and 'Aguardando nova produção' or 'Pronto'
        return true,string.format('%d coletores confirmados · %.0f unidades retiradas',confirmed,total)
end
local function rewards(ctx)
    check(ctx)
    local count=0
    local p=profile()
    for name,quest in pairs(p.questData.activeQuests or {}) do
        check(ctx)
        local cfg=D.quests[name]
        if cfg and not quest.completed and (tonumber(quest.progress) or 0)>=cfg.max and os.clock()>=(cooldown['quest:'..name] or 0) then
            cooldown['quest:'..name]=os.clock()+15
            send(ctx,'TryToCompleteQuest',name)
            if waitUntil(ctx,function()
                local q=profile().questData.activeQuests[name]
                return q and q.completed==true
            end,3) then count+=1 end
        end
    end
    check(ctx)
    p=profile()
    local q=p.questData
    local tier=(tonumber(q.tier) or 0)+1
    if (tonumber(q.tierIncrementProgress) or 0)>=3 and not q.claimedCurrentTier and not (q.claimedTier or {})[tostring(tier)] and os.clock()>=(cooldown.tier or 0) then
        cooldown.tier=os.clock()+15
        send(ctx,'ClaimQuestTier',tostring(tier))
        if waitUntil(ctx,function()
            local data=profile().questData
            return (tonumber(data.tier) or 0)>=tier or (data.claimedTier or {})[tostring(tier)]==true
        end,3) then count+=1 end
    end
    check(ctx)
    local daily=profile().dailyRewards or {}
    local last=tonumber(daily.lastClaimAt) or 0
    local streak=tonumber(daily.streak) or 0
    local canClaim=last==0 and streak==0 or (last>0 and workspace:GetServerTimeNow()-last>=86400)
    if canClaim and os.clock()>=(cooldown.daily or 0) then
        cooldown.daily=os.clock()+30
        send(ctx,'DailyRewardsClaim')
        if waitUntil(ctx,function() return (tonumber(profile().dailyRewards.lastClaimAt) or 0)>last end,3) then count+=1 end
    end
    hub.rewardCount+=count
    return true,string.format('%d recompensas confirmadas',count)
end
local function assignBuilders(ctx)
    check(ctx)
    local unfinished=profile().unfinishedBuildings or {}
    local assigned=0
    local choices={}
    for id,record in pairs(unfinished) do
        assigned+=tonumber(record.assignedBuilders) or 0
        table.insert(choices,{id=id,record=record})
    end
    if (tonumber(player:GetAttribute('Builder')) or 0)<=assigned then return end
    table.sort(choices,function(a,b)
        return (tonumber(a.record.workLeft) or math.huge)<(tonumber(b.record.workLeft) or math.huge)
    end)
    local candidate=choices[1]
    if not candidate or os.clock()<(cooldown['builder:'..candidate.id] or 0) then return end
    local before=tonumber(candidate.record.assignedBuilders) or 0
    cooldown['builder:'..candidate.id]=os.clock()+8
    send(ctx,'AddBuilderToBuilding',candidate.id)
    if waitUntil(ctx,function()
        local current=(profile().unfinishedBuildings or {})[candidate.id]
        return not current or (tonumber(current.assignedBuilders) or 0)>before
    end,3) then hub.assigned+=1 end
end
local function report(err)
    hub.errors+=1; hub.lastError=tostring(err)
    if controls.log then pcall(function() controls.log:Append(tostring(err)) end) end
end
local function runAutoAction(ctx,kind,callback,group,policy)
    check(ctx)
    local action,reason=window:RunAction({
        Id='naval.'..kind..'.auto.action',Group=group,Policy=policy or 'Ignore',
        Callback=callback,
    })
    if not action then
        if reason~='ignored' then report(reason) end
        return
    end
    activeActions[kind]=action
    ctx:Manage(function()
        local status=action:GetStatus().Status
        if status=='Queued' or status=='Running' or status=='Cancelling' then action:Cancel('Tarefa interrompida') end
        if activeActions[kind]==action then activeActions[kind]=nil end
    end)
    repeat
        check(ctx)
        local status=action:GetStatus().Status
        if status=='Completed' or status=='Failed' or status=='Cancelled' then break end
        task.wait(.05)
    until not hub.alive
    check(ctx)
    local status=action:GetStatus()
    if status.Status=='Failed' then report(action.Error or status.Message or 'Ação falhou') end
end
local function reconcile(key,id,enabled)
    if not hub.alive or window:GetFlag(id)~=enabled then return end
    state[key]=enabled
    local job=tasks[key]
    if job then
        if enabled then job:Start()
        else
            job:Stop('Controle desligado')
            if activeActions[key] then activeActions[key]:Cancel('Controle desligado') end
        end
    end
end
function hub:Stop()
    self.epoch+=1
    window:StopAll('Parado pelo usuário')
    window:SetFlags({
        ['naval.collect.enabled']=false,['naval.sell.enabled']=false,
        ['naval.rewards.enabled']=false,['naval.builders.enabled']=false,
        ['naval.collect.mode']='Acumular materiais',
    })
    state.collect=false; state.sell=false; state.rewards=false; state.builders=false
    saleState:Set('Desligada')
    if tasks.hud then tasks.hud:Start() end
    self.status='Automações paradas'
end
function hub:Destroy()
    if self.alive then window:Destroy() end
end
window:OnDestroy(function()
    hub.alive=false; hub.epoch+=1
    state.collect=false; state.sell=false; state.rewards=false; state.builders=false
    if env.GuerraNavalRetro==hub then env.GuerraNavalRetro=nil end
end)

local home=window:CreateTab({Title='Painel',Icon='home',Columns=1})
local summary=home:CreateSection({Title='Economia e produção',Icon='globe'})
controls.summary=summary:AddLabel({Id='naval.status',Title='Situação atual',Default='Carregando...',Icon='info',Height=130,Tooltip='Valores replicados pelo jogo. Contadores são desta execução.'})
summary:AddLabel({Id='naval.analysis',Title='Resultado da análise',Default='Coleta de produção: confirmada no servidor.\nInjeção direta de dinheiro/material: não confirmada.\nColeta e venda têm controles independentes.',Icon='notification',Height=95})
local actionRow=summary:CreateRow({Gap=10,StackAt=440})
actionRow:AddButton({Id='naval.stop',Title='Parar automações',Text='PARAR',Icon='close',Tooltip='Desliga coleta, venda, recompensas e alocação de construtores.',Callback=function() hub:Stop(); return true end})
actionRow:AddButton({Id='naval.unload',Title='Encerrar script',Text='ENCERRAR',Icon='close',Tooltip='Destrói a janela e encerra os trabalhos deste script.',Callback=function() hub:Destroy(); return true end})

local economy=window:CreateTab({Title='Economia',Icon='download',Columns=1})
local production=economy:CreateSection({Title='Coleta e materiais',Icon='folder'})
controls.collect=production:AddToggle({Id='naval.collect.enabled',Title='Auto collect all',Icon='download',Default=false,Tooltip='Coleta produção pronta da sua base. A venda é controlada separadamente.',Floating={Text='COLETAR',MobileOnly=true,Position=Vector2.new(.04,.65)},Callback=function(value) reconcile('collect','naval.collect.enabled',value) end})
production:AddDropdown({Id='naval.collect.mode',Title='Modo de economia (atalho)',Icon='sliders',Options={'Acumular materiais','Coletar e vender'},Default=state.mode,Tooltip='Compatível com perfis antigos: Acumular desliga a venda; Coletar e vender liga a venda periódica. Não altera o intervalo de venda.',Callback=function(value)
    if window:GetFlag('naval.collect.mode')~=value then return end
    state.mode=value
    window:SetFlag('naval.sell.enabled',value=='Coletar e vender')
end})
production:AddDropdown({Id='naval.collect.types',Title='Categorias coletadas',Icon='grid',Options=categoryNames,Default=state.categories,Multi=true,Searchable=true,Tooltip='Seleciona os tipos de coletores. As estruturas precisam estar concluídas e com produção pronta.',Callback=function(value) state.categories=value end})
local timing=production:CreateRow({Gap=10,StackAt=440})
timing:AddSlider({Id='naval.collect.interval',Title='Intervalo da coleta',Icon='sliders',Min=.5,Max=30,Step=.5,Default=2,Suffix=' s',Tooltip='Espera entre ciclos de coleta. O intervalo de venda é separado.',Callback=function(value) state.interval=value; if tasks.collect then tasks.collect:SetInterval(value) end end})
timing:AddSlider({Id='naval.collect.minimum',Title='Produção mínima',Icon='sliders',Min=1,Max=100,Step=1,Default=1,Suffix=' un.',Tooltip='Um coletor só é usado quando tem pelo menos esta quantidade pronta.',Callback=function(value) state.minimum=value end})
controls.collectNow=production:AddButton({Id='naval.collect.now',Title='Coletar agora',Text='COLETAR',Icon='download',Feedback=true,Group='naval.economy',Policy='Reject',Cancelable=true,Tooltip='Executa somente a coleta e aguarda confirmação. Não vende ao finalizar.',Callback=function(_,ctx) return collectAll(ctx,true) end})
local sales=economy:CreateSection({Title='Dinheiro por venda',Icon='bolt'})
controls.sell=sales:AddToggle({Id='naval.sell.enabled',Title='Venda automática de materiais',Icon='upload',Default=false,Description='Liga/desliga a venda sem parar a coleta.',Tooltip='Vende somente recursos desbloqueados a cada intervalo. Desligar cancela novas vendas; um pedido já enviado ao servidor pode concluir.',Callback=function(value)
    if window:GetFlag('naval.sell.enabled')~=value then return end
    state.sell=value
    state.mode=value and 'Coletar e vender' or 'Acumular materiais'
    window:SetFlag('naval.collect.mode',state.mode,true)
    reconcile('sell','naval.sell.enabled',value)
    saleState:Set(value and ('Agendada a cada '..state.sellInterval..' s') or 'Desligada')
end})
sales:AddSlider({Id='naval.sell.interval',Title='Vender a cada',Icon='sliders',Min=1,Max=600,Step=1,Default=10,Suffix=' s',Tooltip='Espera entre vendas completas. Se houver coleta em andamento, a venda aguarda na fila. A primeira venda ocorre após este intervalo.',Callback=function(value)
    state.sellInterval=value
    if tasks.sell then tasks.sell:SetInterval(value) end
    if window:GetFlag('naval.sell.enabled') then saleState:Set('Agendada a cada '..value..' s') end
end})
controls.saleStatus=sales:AddLabel({Id='naval.sell.status',Title='Estado da venda',Default='Desligada',Icon='info',Height=50})
controls.saleStatus:BindState(saleState,{Property='Text',TwoWay=false})
controls.sellNow=sales:AddButton({Id='naval.sell.now',Title='Vender recursos desbloqueados',Text='VENDER',Icon='upload',Feedback=true,Group='naval.economy',Policy='Queue',Cancelable=true,Tooltip='Venda manual, mesmo com venda automática desligada. Aguarda a coleta atual, respeita itens bloqueados e não vende edifícios.',Callback=function(_,ctx) return sellResources(ctx) end})
local farmState=window:Computed({window:GetFlagState('naval.collect.enabled'),window:GetFlagState('naval.sell.enabled')},function(collect,sell) return collect and sell end)
controls.money=sales:AddToggle({Id='naval.money.start',Title='Farm de dinheiro (coleta + venda)',Icon='bolt',Default=false,Persist=false,State=farmState,TwoWay=false,Tooltip='Liga ou desliga coleta e venda juntas. Para parar só a venda e continuar coletando, use Venda automática de materiais.',Callback=function(value)
    local success,reason=window:SetFlags({
        ['naval.collect.enabled']=value,['naval.sell.enabled']=value,
        ['naval.collect.mode']=value and 'Coletar e vender' or 'Acumular materiais',
    })
    if not success then error(reason) end
end})

local progress=window:CreateTab({Title='Progressão',Icon='star',Columns=1})
local rewardSection=progress:CreateSection({Title='Recompensas prontas',Icon='star'})
rewardSection:AddToggle({Id='naval.rewards.enabled',Title='Auto resgatar recompensas',Icon='star',Default=false,Tooltip='Resgata missões concluídas, tiers liberados e a recompensa diária quando estiver disponível.',Callback=function(value) reconcile('rewards','naval.rewards.enabled',value) end})
controls.rewardsNow=rewardSection:AddButton({Id='naval.rewards.now',Title='Verificar e resgatar agora',Text='RESGATAR',Icon='check',Feedback=true,Group='naval.rewards',Policy='Reject',Cancelable=true,Tooltip='Confere os requisitos reais e aguarda confirmação das recompensas disponíveis.',Callback=function(_,ctx) return rewards(ctx) end})
local construction=progress:CreateSection({Title='Construção',Icon='folder'})
construction:AddToggle({Id='naval.builders.enabled',Title='Alocar construtores livres',Icon='user',Default=false,Tooltip='Aloca apenas construtores livres na obra com menor trabalho restante. Não retira trabalhadores de obras já atribuídas.',Callback=function(value) reconcile('builders','naval.builders.enabled',value) end})
controls.construction=construction:AddLabel({Id='naval.builders.status',Title='Fila de obras',Default='Carregando...',Height=65,Icon='info'})
local diagnostics=window:CreateTab({Title='Diagnóstico',Icon='terminal',Columns=1})
local logs=diagnostics:CreateSection({Title='Execução e erros',Icon='terminal'})
controls.log=logs:AddConsole({Id='naval.log',Title='Registro',Height=160,MaxLines=50,Icon='terminal'})
logs:AddButton({Id='naval.refresh',Title='Atualizar lista da base',Text='ATUALIZAR',Icon='refresh',Tooltip='Refaz o cache dos modelos pertencentes à sua base.',Callback=function() models(true); return true end})

tasks.collect=window:CreateTask({Id='naval.collect.task',Interval=state.interval,OnError='Continue',Callback=function(ctx)
    if window:GetFlag('naval.collect.enabled') then runAutoAction(ctx,'collect',function(actionCtx) return collectAll(actionCtx,false) end,'naval.economy') end
end})
tasks.sell=window:CreateTask({Id='naval.sell.task',Interval=state.sellInterval,Immediate=false,OnError='Continue',Callback=function(ctx)
    if not window:GetFlag('naval.sell.enabled') then return end
    saleState:Set('Aguardando espaço para vender')
    runAutoAction(ctx,'sell',function(actionCtx)
        check(actionCtx)
        if not window:GetFlag('naval.sell.enabled') then actionCtx:Cancel('Venda desligada'); check(actionCtx) end
        saleState:Set('Vendendo materiais')
        local success,message=sellResources(actionCtx)
        if hub.alive and window:GetFlag('naval.sell.enabled') then saleState:Set(message) end
        return success,message
    end,'naval.economy','Queue')
end})
tasks.rewards=window:CreateTask({Id='naval.rewards.task',Interval=5,OnError='Continue',Callback=function(ctx)
    if window:GetFlag('naval.rewards.enabled') then runAutoAction(ctx,'rewards',rewards,'naval.rewards') end
end})
tasks.builders=window:CreateTask({Id='naval.builders.task',Interval=5,OnError='Continue',Callback=function(ctx)
    if window:GetFlag('naval.builders.enabled') then assignBuilders(ctx) end
end})
tasks.hud=window:CreateTask({Id='naval.hud.task',Interval=1,Start=true,OnError='Continue',Callback=function(ctx)
            check(ctx)
            local p=profile()
            local readyCount=0
            for _,m in ipairs(models(false)) do if ready(m)>0 then readyCount+=1 end end
            controls.summary:SetText(string.format('%s\nDinheiro: %s · Cristais: %s · Materiais: %.0f\nColetores prontos: %d · Coletas: %d · Unidades: %.0f\nVenda automática: %s · Intervalo: %.0f s\nVendas: %d · Dinheiro registrado: +%.0f\nRecompensas: %d · Erros: %d',hub.status,tostring(p.money),tostring(p.gems or 0),totalMaterials(p),readyCount,hub.collected,hub.units,window:GetFlag('naval.sell.enabled') and 'LIGADA' or 'DESLIGADA',state.sellInterval,hub.sales,hub.earned,hub.rewardCount,hub.errors))
            local works,used=0,0
            for _,record in pairs(p.unfinishedBuildings or {}) do works+=1; used+=tonumber(record.assignedBuilders) or 0 end
            controls.construction:SetText(string.format('%d obras · %.0f / %.0f construtores atribuídos\nAlocações confirmadas nesta execução: %d',works,used,tonumber(player:GetAttribute('Builder')) or 0,hub.assigned))
end})
window:Manage(window:OnError(function(record) report(record.Message) end),'Disconnect')
for key,id in pairs({collect='naval.collect.enabled',sell='naval.sell.enabled',rewards='naval.rewards.enabled',builders='naval.builders.enabled'}) do reconcile(key,id,window:GetFlag(id)) end
hub.controls=controls
hub.tasks=tasks
hub.CollectNow=function() return controls.collectNow:Press() end
hub.SellNow=function() return controls.sellNow:Press() end
hub.RewardsNow=function() return controls.rewardsNow:Press() end
window:Notify({Title='Guerra Naval Hub',Content='RetroBox '..Library.Version..' pronta. Coleta e venda periódica têm controles independentes.',Icon='success',Kind='success',Duration=5})
return hub
end
task.defer(function()
    local ok,err=pcall(main)
    if not ok then warn('Guerra Naval Hub: '..tostring(err)) end
end)
