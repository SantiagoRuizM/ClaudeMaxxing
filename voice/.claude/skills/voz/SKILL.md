---
name: voz
description: Controla ClaudeVoice (lectura en voz alta de las respuestas) en esta sesión de Claude Code. Activar, silenciar, parar, repetir o cambiar la voz.
argument-hint: "[on | off | parar | repetir [n] | repetir-todo [n] | voz <nombre> | sonido [n] | todo-on | todo-off]"
disable-model-invocation: true
allowed-tools: Bash(powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:/Users/user/Documents/CodeHubs/ClaudeVoice/ctl.ps1 session *)
---

!`powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:/Users/user/Documents/CodeHubs/ClaudeVoice/ctl.ps1 session ${CLAUDE_SESSION_ID} $ARGUMENTS`

El comando de arriba ya se ejecutó y su salida es lo que ves. No ejecutes nada más: confirma al usuario el RESULTADO en una sola frase corta.
