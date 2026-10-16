// Package store guarda cada reporte en Valkey con el modelo de datos que lee Grafana.
//
// Claves (todas se actualizan juntas por reporte, en un solo script Lua):
//
//	max:planes, min:planes, max:ships, min:ships   string  máximos y mínimos generales
//	freq:planes, freq:ships                        zset    valor -> veces que apareció
//	mode:planes, mode:ships                        string  valor más frecuente (moda)
//	top:planes, top:ships                          zset    país -> suma acumulada
//	reports:<PAIS>, reports:total                  string  contadores de reportes
//	ts:<PAIS>                                      stream  serie temporal (planes, ships)
package store

import (
	"context"
	"strconv"

	"github.com/valkey-io/valkey-go"

	"mumnk8s/internal/report"
)

// Lua corre dentro de Valkey de forma atómica: ningún otro cliente ve un estado a medias
// y dos consumers no pueden pisarse al comparar y actualizar el máximo o la moda.
//
// El stream se recorta a ~5000 entradas (MAXLEN ~) y tiene TTL de 24 h que se renueva en
// cada escritura: es la única clave que crece con el tiempo, así que es la única con TTL.
const script = `
local country, planes, ships = ARGV[1], tonumber(ARGV[2]), tonumber(ARGV[3])

local function extremos(campo, v)
  local max = tonumber(redis.call('GET', 'max:' .. campo))
  if not max or v > max then redis.call('SET', 'max:' .. campo, v) end
  local min = tonumber(redis.call('GET', 'min:' .. campo))
  if not min or v < min then redis.call('SET', 'min:' .. campo, v) end
end

local function moda(campo, v)
  local n = tonumber(redis.call('ZINCRBY', 'freq:' .. campo, 1, v))
  local actual = redis.call('GET', 'mode:' .. campo)
  local nActual = actual and tonumber(redis.call('ZSCORE', 'freq:' .. campo, actual)) or 0
  if n > nActual then redis.call('SET', 'mode:' .. campo, v) end
end

extremos('planes', planes); extremos('ships', ships)
moda('planes', planes);     moda('ships', ships)
redis.call('ZINCRBY', 'top:planes', planes, country)
redis.call('ZINCRBY', 'top:ships', ships, country)
redis.call('INCR', 'reports:' .. country)
redis.call('INCR', 'reports:total')
redis.call('XADD', 'ts:' .. country, 'MAXLEN', '~', 5000, '*', 'planes', planes, 'ships', ships)
redis.call('EXPIRE', 'ts:' .. country, 86400)
return 1
`

type Store struct {
	client valkey.Client
	lua    *valkey.Lua
}

// New conecta con Valkey. valkey-go mantiene una sola conexión y hace pipelining
// automático: las llamadas concurrentes de los workers viajan juntas sin bloquearse.
func New(addr string) (*Store, error) {
	c, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{addr}})
	if err != nil {
		return nil, err
	}
	// NewLuaScript usa EVALSHA (solo envía el hash) y cae a EVAL si el script no está cargado
	return &Store{client: c, lua: valkey.NewLuaScript(script)}, nil
}

func (s *Store) Guardar(ctx context.Context, r report.WarReport) error {
	args := []string{r.Country, strconv.Itoa(int(r.WarplanesInAir)), strconv.Itoa(int(r.WarshipsInWater))}
	return s.lua.Exec(ctx, s.client, nil, args).Error()
}

func (s *Store) Close() { s.client.Close() }
