regs={}
stat_vars= ['rcnt','rfull','scnt','sarc','sfail']
logger = (data) ->
  #console.log "log>",data
  if data.event==0
    $(".log").html("alku\n")
  for l in data.loglines
    #console.log l
    $(".log").prepend(l.text+"\n")  


dev = (d,obj) ->
  #ret+="<td>#{obj.scnt}<td>"
  for k in stat_vars
      $("#d#{d}r#{k}").html obj[k]
  for k,v of obj.regs
    if (v instanceof Array)
      str=""
      for a in v
        str+=((0x100+a).toString(16).substring(1,3).toUpperCase())
      $("#d#{d}r#{k}").html str
    else
      if regs[k].format =="hex"
        $("#d#{d}r#{k}").html "0x"+((0x100+v).toString(16).substring(1,3).toUpperCase())
      else if regs[k].format =="dec"
        $("#d#{d}r#{k}").html (v).toString(10)
      else
        if regs[k].len
          $("#d#{d}r#{k}").html (0x100+v).toString(2).substring(1+8-regs[k].len,9)
        else
          $("#d#{d}r#{k}").html (0x100+v).toString(2).substring(1,9)

update_status = (data) ->
  #console.log data
  $(".info").html(data.now)
  dev(0,data.devs[0])
  dev(1,data.devs[1])

@build_regs = (regs) ->
  ret="<table>"
  for k,v of regs
    ret+="<tr>"
    ret+="<td >#{v.name}<td>"
    ret+="<td id='d0r#{k}'>d0r#{k}<td>"
    ret+="<td id='d1r#{k}'>d1r#{k}<td>"
    ret+="</tr>"
  ret+="</table>"
  $(".regs").html(ret)
  ret="<table>"
  for k in stat_vars
    ret+="<tr>"
    ret+="<td >#{k}<td>"
    ret+="<td id='d0r#{k}'>d0r#{k}<td>"
    ret+="<td id='d1r#{k}'>d1r#{k}<td>"
    ret+="</tr>"
  ret+="</table>"
  $(".stats").html(ret)

@process_data = (obj) ->
  #console.log "process",obj,obj.type
  if obj.type == "register_table"
    raw_regs=[]
    for k,v of  obj.data
      regs[v.address]=v
      regs[v.address].name=k
    console.log regs
  build_regs regs
  
@ajaxform = (obj) ->
  console.log "doin ajaxform"
  form=$(obj).closest("form")
  key=form.attr('id')
  q=$( form ).serialize()
  console.log q
  $.ajax
    url: "/action.json?#{q}"
    type: "GET"
    processData: false
    contentType: false
    success: (data) ->
      console.log "ajax returns: ", data
      
      return
    error: (xhr, ajaxOptions, thrownError) ->
      alert thrownError
      return

@ajax = (url,obj) ->
  console.log "doin ajax"
  $.ajax
    url: url
    type: "GET"
    processData: false
    contentType: false
    success: (data) ->
      console.log "ajax returns: ", data
      process_data(data)
      return
    error: (xhr, ajaxOptions, thrownError) ->
      alert thrownError
      return

$ ->
  console.log "nRF24 Starts"
  #update_gw()
  #setInterval(->
  #  update_gw()
  #  return
  #, 200000)
  ajax("/init.json",[])
  stream = new EventSource("/nRF24.json")
  stream.addEventListener "message", (event) ->
    update_status($.parseJSON(event.data))
    return
  stream = new EventSource("/logger.json")
  stream.addEventListener "message", (event) ->
    logger($.parseJSON(event.data))
    return