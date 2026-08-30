# noadr
<!--
[![Package Version](https://img.shields.io/hexpm/v/noadr)](https://hex.pm/packages/noadr)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/noadr/)
-->

Nord Pool Day-ahead electricity prices to OpenADR 3 bridge.

In order to run this you will need to have Gleam [installed](https://gleam.run/install/).
```sh
git clone https://github.com/karlsson/noadr.git
cd noadr
gleam run
```
Will start a webserver listening on port 8000 on localhost.

### Programs
OpenADR "Programs" will list available areas. Check the Nord Pool [Day-ahead](https://data.nordpoolgroup.com/auction/day-ahead/prices?deliveryDate=latest&currency=SEK&aggregation=DeliveryPeriod&deliveryAreas=DK1,DK2,FI,NO1,NO2,NO3,NO4,NO5,SE1,SE2,SE3,SE4) page.
All programs may be listed as:
`http://localhost:8000/programs`.

Specific program info e.g.: `http://localhost:8000/programs/SE3`.

### Events
All events for a specific program (area) e.g.:
`http://localhost:8000/events?programID=SE3`
will fetch Day-ahead prices from
Nord Pool server for area SE3 and convert to OpenADR 3 format.
It will fetch both todays prices and, if available, tomorrows prices. Nord Pool prices are divided into 15 min intervals for a 24 hour period.

A specific event:
`http://localhost:8000/events/{eventID}`.
 



**NOTE** : This is really alpha version and request/reply formats may change.

Todos:
* Cache fetched price data.
* Current prices is from Energy providers but a large part of the total price is added by the Grid net owners, so some means to incorporate these would be interesting.
* ..


Inspired by Don Jackson's [Grid Coordination](https://github.com/grid-coordination/price-server-user-guide) price server.
<!--
```gleam
import noadr

pub fn main() -> Nil {
  // TODO: An example of the project in use
}
```

Further documentation can be found at <https://hexdocs.pm/noadr>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
-->
